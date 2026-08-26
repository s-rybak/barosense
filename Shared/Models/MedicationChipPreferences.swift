import Foundation

/// Which remembered medication chips the user has asked not to be offered again.
///
/// ## Why hiding and not deleting
///
/// The chips in the "Add medication" sheet are not a list the app keeps — they are
/// `MedicationHistory` reading back the user's own past entries (see that type: recall, never
/// suggestion). So "remove this chip" cannot be a delete, because there is no row behind it
/// that is *only* the chip: the row behind it is a check-in the user recorded, part of the
/// history the "My medications" screen reports and part of what the model is fit on. Deleting
/// it to tidy a chip row would silently rewrite the log.
///
/// This is the other half of that: a set of strings the sheet skips when it builds its rows.
/// The entries stay in the log, the "My medications" screen keeps counting them, and the chip
/// stops being offered. A typo typed once, or a dose no longer taken, goes away from the place
/// it is in the way without taking a record with it.
///
/// ## What is stored
///
/// The user's own words, which is why an erase clears it (`BarosenseDataEraser`) while the
/// WeatherKit switch and the language row survive one: those are settings, this is text the
/// user typed.
///
/// Synchronous, like `ReminderPreferenceStore` and for its reason: the sheet reads it while
/// building a row, and an `async` read would put a chip row behind a suspension point.
protocol MedicationChipStore: Sendable {

    /// Folded names the sheet must not offer. See `MedicationHistory.key(_:)` for the fold.
    func hiddenNames() -> Set<String>

    func hideName(_ name: String)

    /// Folded doses the sheet must not offer under `name`.
    ///
    /// Keyed by medication rather than global, because a dose only means anything next to the
    /// thing it is a dose *of*: hiding "400 mg" because it is wrong for one medication would
    /// otherwise take it away from every other one the user records it for.
    ///
    /// `nil` is the bucket for the unfiltered row — the doses offered before a name has been
    /// chosen, or for a name with no history of its own.
    func hiddenDoses(for name: String?) -> Set<String>

    func hideDose(_ dose: String, for name: String?)

    /// Drops every hidden chip, so the sheet offers the full history again.
    func reset()
}

/// `UserDefaults`-backed `MedicationChipStore`.
///
/// One defaults key holding a dictionary rather than a key per medication: the whole set is
/// read on every sheet presentation and written on every removal, both of which want one
/// round trip, and a key-per-name scheme would leave orphaned keys behind an erase.
///
/// The empty-string key is the `nil` bucket described on the protocol. Spelled as a constant
/// rather than written inline at the three call sites, because a bucket that is a bare `""`
/// somewhere is the kind of thing that becomes two buckets.
struct UserDefaultsMedicationChipStore: MedicationChipStore {

    private enum Keys {
        static let hiddenNames = "barosense.medication.hiddenNames.v1"
        static let hiddenDoses = "barosense.medication.hiddenDoses.v1"
    }

    /// Where the doses hidden for "no particular medication" live.
    private static let unfilteredBucket = ""

    /// `nonisolated(unsafe)` for the reason the reminder and WeatherKit stores give:
    /// `UserDefaults` is thread-safe but not marked `Sendable`, and the alternative is an
    /// actor around a synchronous API the callers need synchronously.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hiddenNames() -> Set<String> {
        Set(defaults.stringArray(forKey: Keys.hiddenNames) ?? [])
    }

    func hideName(_ name: String) {
        let key = MedicationHistory.key(name)
        guard !key.isEmpty else { return }

        var hidden = hiddenNames()
        guard hidden.insert(key).inserted else { return }

        defaults.set(Array(hidden), forKey: Keys.hiddenNames)
    }

    func hiddenDoses(for name: String?) -> Set<String> {
        Set(storedDoses()[bucket(for: name)] ?? [])
    }

    func hideDose(_ dose: String, for name: String?) {
        let key = MedicationHistory.key(dose)
        guard !key.isEmpty else { return }

        let bucket = bucket(for: name)
        var stored = storedDoses()
        var hidden = Set(stored[bucket] ?? [])
        guard hidden.insert(key).inserted else { return }

        stored[bucket] = Array(hidden)
        defaults.set(stored, forKey: Keys.hiddenDoses)
    }

    func reset() {
        defaults.removeObject(forKey: Keys.hiddenNames)
        defaults.removeObject(forKey: Keys.hiddenDoses)
    }

    private func bucket(for name: String?) -> String {
        guard let name else { return Self.unfilteredBucket }

        let key = MedicationHistory.key(name)
        return key.isEmpty ? Self.unfilteredBucket : key
    }

    /// `[String: [String]]` and not `[String: Set<String>]`: a property list has no set type,
    /// so the array is what actually goes to disk and pretending otherwise here would mean a
    /// cast that fails at read time rather than at write time.
    private func storedDoses() -> [String: [String]] {
        defaults.dictionary(forKey: Keys.hiddenDoses) as? [String: [String]] ?? [:]
    }
}

/// In-memory `MedicationChipStore`, for tests and previews.
///
/// A reference type behind a lock rather than a struct, because the thing under test is that a
/// removal is *observed* by the next read — a value-semantics double would make every test
/// pass by construction.
final class InMemoryMedicationChipStore: MedicationChipStore, @unchecked Sendable {

    private let lock = NSLock()
    private var names: Set<String> = []
    private var doses: [String: Set<String>] = [:]

    init(names: Set<String> = [], doses: [String: Set<String>] = [:]) {
        self.names = names
        self.doses = doses
    }

    func hiddenNames() -> Set<String> {
        lock.withLock { names }
    }

    func hideName(_ name: String) {
        let key = MedicationHistory.key(name)
        guard !key.isEmpty else { return }

        lock.withLock { _ = names.insert(key) }
    }

    func hiddenDoses(for name: String?) -> Set<String> {
        lock.withLock { doses[bucket(for: name)] ?? [] }
    }

    func hideDose(_ dose: String, for name: String?) {
        let key = MedicationHistory.key(dose)
        guard !key.isEmpty else { return }

        lock.withLock { _ = doses[bucket(for: name), default: []].insert(key) }
    }

    func reset() {
        lock.withLock {
            names = []
            doses = [:]
        }
    }

    private func bucket(for name: String?) -> String {
        guard let name else { return "" }

        let key = MedicationHistory.key(name)
        return key.isEmpty ? "" : key
    }
}
