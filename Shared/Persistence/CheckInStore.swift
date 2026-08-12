import Foundation

/// Storage for self-reported check-ins.
///
/// A protocol so the feature pipeline and its tests depend on this and not on SwiftData:
/// the model has to be runnable from a plain unit test with synthetic input. The durable
/// implementation is injected at the app layer.
///
/// Check-ins are health data. An implementation keeps them on-device unless the user has
/// given separate, explicit consent to sync — see `CLAUDE.md`, constraint 2. That is a
/// property of the implementation, not something a caller can opt into here.
protocol CheckInStore: Sendable {

    /// Inserts a check-in, or replaces the stored one carrying the same `id`.
    ///
    /// Replace-on-same-id is what makes the watch→phone transfer idempotent: a payload
    /// delivered twice must not produce two training rows.
    func save(_ checkIn: CheckIn) async throws

    /// Check-ins whose timestamp falls in `range`, ascending by timestamp.
    ///
    /// Half-open: `lowerBound` included, `upperBound` excluded, so adjacent windows can
    /// be requested without counting the boundary check-in twice. The ordering is part of
    /// the contract — features read neighbouring rows and cannot re-sort what they are
    /// streamed.
    func checkIns(in range: Range<Date>) async throws -> [CheckIn]

    /// The latest check-in strictly before `date`, if there is one.
    ///
    /// Backs `priorCheckInScore` and `hoursSincePriorCheckIn`. Strictly before, so a
    /// feature computed at a check-in's own timestamp cannot pick up that check-in and
    /// leak its own label into the row.
    func mostRecentCheckIn(before date: Date) async throws -> CheckIn?

    /// Removes the check-in with this `id`. Deleting something absent is not an error.
    func delete(id: UUID) async throws

    /// Removes every stored check-in.
    ///
    /// The counterpart to `WellbeingTagStore.deleteAllTags`, and it exists for the same
    /// single caller: "delete my data" (`BarosenseDataEraser`). Separate from `delete(id:)`
    /// rather than left to the caller as a loop, because the caller is an erase that must
    /// not have to read every row of the most personal table on the device — the note and
    /// the medication list — in order to remove it.
    func deleteAllCheckIns() async throws
}
