import Foundation

/// What the user has recorded taking before, offered back to them as chips (Figma
/// `Додати ліки` — "Твої засоби" and "Дозування").
///
/// **Recall, not suggestion.** Every string returned here was typed by the user on an earlier
/// check-in. Nothing ships with the app, nothing is inferred from what they took, and the only
/// ordering is when it was last used. That distinction is the whole reason this is a separate
/// type with a name that says so: a list the *app* proposed would be the app telling someone
/// what to take, which is exactly the claim `MedicationEntry` exists not to make.
///
/// Pure functions over values the caller already has. No store, no clock, no I/O — the caller
/// decides how far back "before" reaches.
enum MedicationHistory {

    /// Distinct medication names, most recently taken first.
    static func names(in entries: [MedicationEntry], limit: Int = 8) -> [String] {
        distinct(mostRecentFirst(entries).map(\.name), limit: limit)
    }

    /// Distinct doses, most recently taken first.
    ///
    /// Narrowed to `name` when one is given, which is what makes a thing the user always takes
    /// the same amount of a two-tap entry. `nil` — no name chosen yet, or one with no history —
    /// falls back to every dose they have used, because an unfiltered list of their own words is
    /// still better than an empty row.
    static func doses(in entries: [MedicationEntry], for name: String? = nil, limit: Int = 6) -> [String] {
        let matching = matches(entries, name: name)
        return distinct(mostRecentFirst(matching).compactMap(\.dose), limit: limit)
    }

    /// Entries for `name`, or all of them when there is no name or the name is new.
    private static func matches(_ entries: [MedicationEntry], name: String?) -> [MedicationEntry] {
        guard let key = name.map(folded), !key.isEmpty else { return entries }

        let matching = entries.filter { folded($0.name) == key }
        return matching.isEmpty ? entries : matching
    }

    /// Newest first, ties broken by name so the order is the same on every call.
    ///
    /// `Array.sorted(by:)` is not documented as stable, and these lists feed a chip row the
    /// user is expected to build muscle memory on — chips that reshuffle between two openings
    /// of the same sheet are worse than chips in a mildly odd order.
    private static func mostRecentFirst(_ entries: [MedicationEntry]) -> [MedicationEntry] {
        entries.sorted { lhs, rhs in
            lhs.takenAt == rhs.takenAt ? lhs.name < rhs.name : lhs.takenAt > rhs.takenAt
        }
    }

    /// First occurrence wins, so the spelling kept is the most recent one the user typed.
    private static func distinct(_ values: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }

        var seen: Set<String> = []
        var result: [String] = []

        for value in values {
            guard seen.insert(folded(value)).inserted else { continue }

            result.append(value)
            if result.count == limit { break }
        }

        return result
    }

    /// The key two spellings are considered the same under: case and surrounding whitespace.
    ///
    /// Case only — **not** diacritic-insensitive. Folding diacritics would merge `й` into `и`
    /// and `ї` into `і`, which are different letters in Ukrainian, not accented forms of one.
    /// A fold that is right for one language and wrong for the reader's own is worse than no
    /// fold at all.
    private static func folded(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
