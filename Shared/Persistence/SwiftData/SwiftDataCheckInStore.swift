import Foundation
import SwiftData

/// Durable row for `CheckIn`.
///
/// On the main `BarosenseModelContainer` schema rather than in a store of its own, unlike the
/// two sensor logs: a check-in points at the tag vocabulary, and keeping the two in one file
/// means a future query that joins them does not have to cross a container boundary.
///
/// Tag identity is stored with the same encoding `StoredWellbeingTag` uses, reusing its
/// helpers rather than re-deriving the format. Two encodings for one identity is how a
/// check-in ends up pointing at a tag that exists but cannot be found.
@Model
final class StoredCheckIn {

    /// Indexed on `timestamp` because every read is a window over it — the chart asks for a
    /// trailing range, the feature pipeline asks for the row before `t`.
    #Index<StoredCheckIn>([\.timestamp])

    /// The check-in's own identifier, carried across from the domain value. Unique, so a
    /// payload delivered twice — the watch→phone transfer this store is waiting for —
    /// replaces its row instead of producing a second training row.
    @Attribute(.unique) var id: UUID = UUID()

    var timestamp: Date = Date.distantPast

    /// `WellbeingScore.rawValue`. Stored as its raw `Int` rather than as the enum: the raw
    /// values are the storage format (`Shared/Models/CheckIn.swift`), and a row written with
    /// a value outside 1–5 has to be rejectable on read rather than crashing the history.
    var scoreRawValue: Int = 0

    var tagIdentityKeys: [String] = []

    var note: String?

    init(checkIn: CheckIn) {
        self.id = checkIn.id
        apply(checkIn)
    }

    func apply(_ checkIn: CheckIn) {
        timestamp = checkIn.timestamp
        scoreRawValue = checkIn.score.rawValue
        tagIdentityKeys = checkIn.tagIDs
            .map(StoredWellbeingTag.identityKey(for:))
            .sorted()
        note = checkIn.note
    }

    /// `nil` when the stored score is not a point on the 1–5 scale — a row written by a build
    /// that knew a wider scale. Skipped on read instead of being clamped into a neighbouring
    /// score: a fabricated label is worse than a missing one, and every metric in
    /// `.claude/context/ml-spec.md` §7 is computed against this value.
    var checkIn: CheckIn? {
        guard let score = WellbeingScore(rawValue: scoreRawValue) else { return nil }

        return CheckIn(id: id,
                       timestamp: timestamp,
                       score: score,
                       // Keys that no longer parse are dropped rather than failing the row:
                       // the check-in and its score are the training data, the tags are
                       // context that does not enter the v1 label.
                       tagIDs: Set(tagIdentityKeys.compactMap(StoredWellbeingTag.identity(from:))),
                       note: note)
    }
}

/// On-disk `CheckInStore`.
///
/// A `@ModelActor` like the other stores: the `ModelContext` stays on its executor and only
/// `CheckIn` values come out, so no `@Model` instance crosses an isolation boundary.
///
/// Check-ins are health data and stay on the device. That is not enforced here — it is
/// enforced by `BarosenseModelContainer` opening every configuration with
/// `cloudKitDatabase: .none`, which is `CLAUDE.md` constraint 2 in code.
@ModelActor
actor SwiftDataCheckInStore: CheckInStore {

    func save(_ checkIn: CheckIn) throws {
        let id = checkIn.id
        let descriptor = FetchDescriptor<StoredCheckIn>(predicate: #Predicate { $0.id == id })

        if let existing = try modelContext.fetch(descriptor).first {
            existing.apply(checkIn)
        } else {
            modelContext.insert(StoredCheckIn(checkIn: checkIn))
        }
        try modelContext.save()
    }

    func checkIns(in range: Range<Date>) throws -> [CheckIn] {
        let lower = range.lowerBound
        let upper = range.upperBound

        let descriptor = FetchDescriptor<StoredCheckIn>(
            predicate: #Predicate { $0.timestamp >= lower && $0.timestamp < upper },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )

        return try modelContext.fetch(descriptor).compactMap(\.checkIn)
    }

    /// The row before `date`, or `nil`.
    ///
    /// One row is fetched, not a window that is then filtered: this backs
    /// `hoursSincePriorCheckIn`, which is computed per training row, and a scan of the whole
    /// history per row is quadratic over a table that grows for the life of the install.
    ///
    /// A single fetched row that will not map (see `StoredCheckIn.checkIn`) reports `nil`
    /// rather than reaching further back. "No prior check-in" is a state the features already
    /// handle — they go nil and the row is dropped — whereas silently skipping to an older
    /// one would make `hoursSincePriorCheckIn` describe a different check-in than the one that
    /// is actually there.
    func mostRecentCheckIn(before date: Date) throws -> CheckIn? {
        var descriptor = FetchDescriptor<StoredCheckIn>(
            predicate: #Predicate { $0.timestamp < date },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        return try modelContext.fetch(descriptor).first?.checkIn
    }

    func delete(id: UUID) throws {
        let descriptor = FetchDescriptor<StoredCheckIn>(predicate: #Predicate { $0.id == id })
        guard let existing = try modelContext.fetch(descriptor).first else { return }

        modelContext.delete(existing)
        try modelContext.save()
    }
}
