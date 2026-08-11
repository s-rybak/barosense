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

    /// `CheckInIntensity.rawValue`. Stored as its raw `Int` rather than as the type: the raw
    /// values are the storage format (`Shared/Models/CheckIn.swift`), and a row written with
    /// a value outside 1–10 has to be rejectable on read rather than crashing the history.
    ///
    /// This attribute replaced a `scoreRawValue` holding a 1–5 wellbeing score, where **1 was
    /// the worst**. Renaming it rather than reusing it is the point: the two scales run in
    /// opposite directions, so a row carrying the old `2` ("poor") would read as the new `2`
    /// ("barely there") — the same number meaning the opposite thing, silently. A new
    /// attribute leaves those rows at the `0` default, which fails the range check below and
    /// drops them. Losing a pre-release check-in is cheap; inverting one is not.
    var intensityRawValue: Int = 0

    var tagIdentityKeys: [String] = []

    /// What the user recorded taking, in entry order.
    ///
    /// A storage-owned struct rather than `MedicationEntry` itself, for the reason the tag
    /// keys are strings and not `WellbeingTag.ID`s: the domain type is free to change shape,
    /// and a stored blob that decodes straight into it would make every such change a
    /// migration nobody noticed writing.
    var medications: [StoredMedication] = []

    var note: String?

    init(checkIn: CheckIn) {
        self.id = checkIn.id
        apply(checkIn)
    }

    func apply(_ checkIn: CheckIn) {
        timestamp = checkIn.timestamp
        intensityRawValue = checkIn.intensity.rawValue
        tagIdentityKeys = checkIn.tagIDs
            .map(StoredWellbeingTag.identityKey(for:))
            .sorted()
        medications = checkIn.medications.map(StoredMedication.init(entry:))
        note = checkIn.note
    }

    /// `nil` when the stored intensity is not a point on the 1–10 scale — a row written by a
    /// build that knew a different scale, including every row written before this attribute
    /// existed. Skipped on read instead of being clamped into a neighbouring value: a
    /// fabricated label is worse than a missing one, and every metric in
    /// `.claude/context/ml-spec.md` §7 is computed against this value.
    var checkIn: CheckIn? {
        guard let intensity = CheckInIntensity(rawValue: intensityRawValue) else { return nil }

        return CheckIn(id: id,
                       timestamp: timestamp,
                       intensity: intensity,
                       // Keys that no longer parse are dropped rather than failing the row:
                       // the check-in and its intensity are the training data, the tags are
                       // context that does not enter the v1 label.
                       tagIDs: Set(tagIdentityKeys.compactMap(StoredWellbeingTag.identity(from:))),
                       // Same rule, same reason: an entry that will not map is dropped and
                       // the check-in survives.
                       medications: medications.compactMap { $0.entry(fallbackTakenAt: timestamp) },
                       note: note)
    }
}

/// Durable form of one `MedicationEntry`.
///
/// A plain `Codable` value stored inline on `StoredCheckIn` rather than a `@Model` of its
/// own: these rows are only ever read as part of the check-in that owns them, and a separate
/// model would buy a relationship to keep consistent in exchange for a query nothing makes.
struct StoredMedication: Codable, Hashable {

    var id: UUID
    var name: String
    var dose: String?

    /// Optional in storage while it is required in the domain, and that asymmetry is the point:
    /// a blob written before this attribute existed decodes with `nil` here instead of failing
    /// and taking the whole check-in's medication list with it. The reader supplies the
    /// fallback, because the only defensible one is the check-in's own timestamp and this
    /// struct does not know it.
    var takenAt: Date?

    init(entry: MedicationEntry) {
        id = entry.id
        name = entry.name
        dose = entry.dose
        takenAt = entry.takenAt
    }

    /// `nil` when the stored name is blank — `MedicationEntry` refuses to exist without one,
    /// and a row that predates that rule must not be able to smuggle one in.
    ///
    /// A missing time falls back to `fallbackTakenAt`, the timestamp of the check-in that owns
    /// the entry. That is a guess, and it is the least wrong one available: before the sheet
    /// had a time control every entry *was* recorded at its check-in's moment.
    func entry(fallbackTakenAt: Date) -> MedicationEntry? {
        MedicationEntry(id: id, name: name, dose: dose, takenAt: takenAt ?? fallbackTakenAt)
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
