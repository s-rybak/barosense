import Foundation

/// Everything one medication's entries add up to, for the "My medications" screen.
///
/// Four facts, all of them the user's own: what they called it, the amounts they wrote, how
/// many times they wrote it down, and when that last was. There is deliberately no fifth —
/// nothing here relates a medication to how the user felt, and nothing schedules the next one.
struct MedicationSummary: Identifiable, Hashable, Sendable {

    /// The most recent spelling the user used. Unique across a result — entries differing only
    /// by case are one row — so it also serves as identity for a list.
    let name: String

    /// Distinct doses recorded for it, most recently used first. Empty when they never gave one.
    let doses: [String]

    /// How many entries carry this name. Two of the same thing on one day counts twice.
    let timesTaken: Int

    let lastTakenAt: Date

    var id: String { name }
}

/// How the "My medications" list is arranged.
///
/// Two orders and no third: both are properties of the log itself. Nothing here ranks a
/// medication by how much of it was taken or by how the user felt around it — an order is a
/// way of finding a row, not a statement about it.
enum MedicationOrder: String, CaseIterable, Identifiable, Sendable {

    /// Most recently taken first. The default, because a list opened straight after writing
    /// something down should have that thing at the top.
    case recent

    /// A–Z by name, collated the way the reader's own language collates it.
    case name

    var id: String { rawValue }
}

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

    /// One row per distinct medication, most recently taken first — what the "My medications"
    /// screen lists.
    ///
    /// Same rule as everything else here: this is the user's own log grouped, nothing more. It
    /// reports how many times they wrote something down and which amounts they wrote, and it
    /// does not total doses, work out an interval, or say anything about any of it.
    static func summaries(in entries: [MedicationEntry]) -> [MedicationSummary] {
        var order: [String] = []
        var grouped: [String: [MedicationEntry]] = [:]

        for entry in mostRecentFirst(entries) {
            let key = folded(entry.name)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(entry)
        }

        return order.compactMap { key in
            guard let group = grouped[key], let newest = group.first else { return nil }

            return MedicationSummary(name: newest.name,
                                     doses: distinct(group.compactMap(\.dose), limit: .max),
                                     timesTaken: group.count,
                                     lastTakenAt: newest.takenAt)
        }
    }

    /// The same summaries, arranged. Separate from `summaries(in:)` rather than a parameter on
    /// it, so a screen can re-arrange rows it already holds without going back to the store:
    /// grouping the log is the expensive half, and it does not change when the order does.
    ///
    /// `localizedStandardCompare` rather than `<`. Comparing `String` directly orders by Unicode
    /// scalar, which puts every Cyrillic name after every Latin one and sorts "ібупрофен" away
    /// from "Ібупрофен" — an alphabetical order that is not the reader's alphabet is not the
    /// feature they asked for.
    static func ordered(_ summaries: [MedicationSummary],
                        by order: MedicationOrder) -> [MedicationSummary] {
        guard order == .name else { return summaries }

        // Decorated with the incoming index because `sorted(by:)` is not documented as stable
        // and the input is already in a meaningful order. Two names a locale collates as equal
        // then keep their recency order instead of swapping between redraws.
        return summaries.enumerated()
            .sorted { lhs, rhs in
                switch lhs.element.name.localizedStandardCompare(rhs.element.name) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: lhs.offset < rhs.offset
                }
            }
            .map(\.element)
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
