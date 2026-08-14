import Foundation
import SwiftData

/// Durable row for `NotificationRecord`.
///
/// On the main `BarosenseModelContainer` schema rather than a container of its own, unlike the
/// two sensor logs: the reminder this table drives is planned off the check-in table, and one
/// container means the two cannot be opened separately and disagree about which rows exist.
///
/// The row carries no health data. See `NotificationRecord` for why the copy is not stored here
/// either.
@Model
final class StoredNotification {

    /// Indexed on `scheduledFor` because every read is a window over it — the budget asks for one
    /// day, the dispatcher asks for everything still ahead, the prune asks for everything behind.
    #Index<StoredNotification>([\.scheduledFor])

    /// The record's own identifier, carried across from the domain value, and the same string the
    /// notification is registered under with the system. Unique, so a second save of a row whose
    /// state moved replaces it rather than logging the same notification twice.
    @Attribute(.unique) var id: UUID = UUID()

    /// `NotificationKind.rawValue`. Stored as its raw `String` rather than as the type, for the
    /// reason `StoredCheckIn` stores a raw `Int`: the raw values are the storage format, and a
    /// row written by a build that knew a kind this one does not has to be rejectable on read
    /// rather than crashing the log.
    var kindRawValue: String = ""

    /// `AppLanguage.rawValue`, same rule. Which language the system was handed, so a switch in
    /// Settings can be seen as one — see `NotificationRecord.language`.
    var languageRawValue: String = ""

    var scheduledFor: Date = Date.distantPast

    /// `NotificationDeliveryState.rawValue`, same rule.
    var stateRawValue: String = ""

    var stateChangedAt: Date = Date.distantPast

    var createdAt: Date = Date.distantPast

    init(record: NotificationRecord) {
        self.id = record.id
        apply(record)
    }

    func apply(_ record: NotificationRecord) {
        kindRawValue = record.kind.rawValue
        languageRawValue = record.language.rawValue
        scheduledFor = record.scheduledFor
        stateRawValue = record.state.rawValue
        stateChangedAt = record.stateChangedAt
        createdAt = record.createdAt
    }

    /// `nil` when the kind, the language or the state will not map — a row written by a build
    /// that knew one this one does not, including every row written before this table existed
    /// and every row naming a language this build has dropped.
    ///
    /// Skipped on read rather than coerced into a neighbouring value. The consequence of a guess
    /// here is not cosmetic: a row misread as `.suppressed` when it was `.delivered` hands the
    /// day an allowance it has already spent, which is exactly the failure the cap exists to
    /// prevent.
    var record: NotificationRecord? {
        guard let kind = NotificationKind(rawValue: kindRawValue),
              let language = AppLanguage(rawValue: languageRawValue),
              let state = NotificationDeliveryState(rawValue: stateRawValue)
        else {
            return nil
        }

        return NotificationRecord(id: id,
                                  kind: kind,
                                  language: language,
                                  scheduledFor: scheduledFor,
                                  state: state,
                                  createdAt: createdAt,
                                  stateChangedAt: stateChangedAt)
    }
}

/// On-disk `NotificationStore`.
///
/// A `@ModelActor` like the other stores: the `ModelContext` stays on its executor and only
/// `NotificationRecord` values come out, so no `@Model` instance crosses an isolation boundary.
@ModelActor
actor SwiftDataNotificationStore: NotificationStore {

    func save(_ record: NotificationRecord) throws {
        let id = record.id
        let descriptor = FetchDescriptor<StoredNotification>(predicate: #Predicate { $0.id == id })

        if let existing = try modelContext.fetch(descriptor).first {
            existing.apply(record)
        } else {
            modelContext.insert(StoredNotification(record: record))
        }
        try modelContext.save()
    }

    func records(in range: Range<Date>) throws -> [NotificationRecord] {
        let lower = range.lowerBound
        let upper = range.upperBound

        let descriptor = FetchDescriptor<StoredNotification>(
            predicate: #Predicate { $0.scheduledFor >= lower && $0.scheduledFor < upper },
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )

        return try modelContext.fetch(descriptor).compactMap(\.record)
    }

    /// Filtered on the state in Swift rather than in the predicate.
    ///
    /// `#Predicate` cannot compare against a `String` derived from an enum case inside the
    /// closure, and hoisting the raw value into a local would put the storage format in two
    /// places. The fetch is already narrowed to the future by the index, which is the part that
    /// would otherwise scan.
    func pendingRecords(notBefore date: Date) throws -> [NotificationRecord] {
        let descriptor = FetchDescriptor<StoredNotification>(
            predicate: #Predicate { $0.scheduledFor >= date },
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )

        return try modelContext.fetch(descriptor)
            .compactMap(\.record)
            .filter { $0.state == .scheduled }
    }

    @discardableResult
    func deleteNotifications(before date: Date) throws -> Int {
        let descriptor = FetchDescriptor<StoredNotification>(
            predicate: #Predicate { $0.scheduledFor < date }
        )

        let doomed = try modelContext.fetch(descriptor)
        for row in doomed {
            modelContext.delete(row)
        }
        try modelContext.save()

        return doomed.count
    }

    /// A batch delete rather than a fetch-then-delete loop, as `SwiftDataCheckInStore` uses:
    /// this table grows for the life of the install, and materialising every row just to remove
    /// it is memory spent at the moment the user has asked for their data to be gone.
    func deleteAllNotifications() throws {
        try modelContext.delete(model: StoredNotification.self)
        try modelContext.save()
    }
}
