import Foundation

/// Everything a shareable report prints, resolved into one value.
///
/// A snapshot, not a view onto the stores. Once built, nothing in it can change underneath
/// the document: tag names are already resolved to the text they had when the report was
/// made, and every figure was counted in one pass. That is what makes the on-screen preview
/// and the PDF the same document rather than two reads of a moving store.
///
/// Counts and the user's own entries. Nothing here scores a period, ranks one window against
/// another, or relates pressure to how the user felt — the same rule `CheckInHistory` states
/// for the History screen, and here it is also what keeps a document intended for another
/// reader from making a claim the app is not allowed to make.
struct WellbeingReport: Hashable, Sendable {

    let period: ReportPeriod

    /// Half-open, from `ReportPeriod.window(endingOn:calendar:)`.
    let window: Range<Date>

    /// Last day the window covers — what the header prints as the closing date.
    let lastCoveredDay: Date

    let generatedAt: Date

    let profile: ReportProfile
    let totals: ReportTotals

    /// `nil` when the window holds no check-in, which is also when there is no scale to
    /// average.
    let intensity: ReportIntensityDigest?

    /// One point per day of the window, in order. Days with nothing recorded are present and
    /// empty rather than absent, so the chart draws a gap instead of joining across it.
    let trace: [ReportTracePoint]

    /// Most-used first, names already resolved.
    let tags: [ReportTagCount]

    /// What the user recorded taking, grouped — `MedicationHistory.summaries`.
    let medications: [MedicationSummary]

    /// The log itself, newest first.
    let entries: [ReportEntry]

    /// What the document was built from, for the "Data sources" block.
    let sources: [ReportSource]

    /// Nothing was recorded in the window at all. The document is still generated — an empty
    /// period is a fact about the period, and a reader who asked for one is entitled to see
    /// that it is empty rather than to be refused a file.
    var isEmpty: Bool {
        totals.checkInCount == 0 && totals.pressureReadingCount == 0 && totals.healthReadingCount == 0
    }
}

// MARK: - Profile

/// How the report identifies the person it is about.
///
/// Three fields, all optional, all the user's own answers from onboarding. Deliberately no
/// fourth: the report says who it describes and stops there.
struct ReportProfile: Hashable, Sendable {

    let displayName: String?
    let ageYears: Int?
    let gender: Gender?

    /// Nothing to print. The block is left out entirely rather than drawn with three blanks —
    /// a labelled empty field reads as data that failed to load.
    var isEmpty: Bool {
        displayName == nil && ageYears == nil && gender == nil
    }

    init(displayName: String? = nil, ageYears: Int? = nil, gender: Gender? = nil) {
        // A name that is blank once trimmed is not a name, and printing one would put an
        // empty labelled row in a document someone else reads.
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.ageYears = ageYears
        self.gender = gender
    }
}

// MARK: - Totals

/// The figures at the head of the report. Counts only.
struct ReportTotals: Hashable, Sendable {

    let checkInCount: Int

    /// Distinct days carrying at least one check-in — not the same as `checkInCount`, and the
    /// more useful of the two for a reader skimming a quarter: five entries on one day and
    /// five spread across five days are different periods.
    let daysWithEntries: Int

    /// One per thing recorded, so the same thing taken twice counts twice — the rule
    /// `HistorySummary.medicationCount` already follows.
    let medicationEntryCount: Int

    let pressureReadingCount: Int

    /// Readings across every kind in `HealthMetricKind`, as they reached the training log.
    let healthReadingCount: Int

    static let empty = ReportTotals(checkInCount: 0,
                                    daysWithEntries: 0,
                                    medicationEntryCount: 0,
                                    pressureReadingCount: 0,
                                    healthReadingCount: 0)
}

/// What the user reported on the 1–10 scale, summarised.
///
/// Three numbers the user themselves wrote down, restated. Not a score, not a severity
/// rating, and not comparable to anyone else's — the scale is self-anchored, which is why the
/// report always prints it beside its range.
struct ReportIntensityDigest: Hashable, Sendable {

    /// Arithmetic mean over the check-ins in the window.
    let mean: Double

    let peak: CheckInIntensity
    let lowest: CheckInIntensity

    /// `nil` for an empty window — there is no mean of nothing, and a 0 printed on a 1–10
    /// scale would read as a value off the bottom of it.
    init?(checkIns: [CheckIn]) {
        let intensities = checkIns.map(\.intensity)
        guard let peak = intensities.max(), let lowest = intensities.min() else { return nil }

        mean = Double(intensities.reduce(0) { $0 + $1.rawValue }) / Double(intensities.count)
        self.peak = peak
        self.lowest = lowest
    }
}

// MARK: - Trace

/// One day of the report's chart: what the barometer averaged, and the worst the user
/// reported.
///
/// The two are drawn on one timeline and nothing joins them. Putting them on the same axis is
/// what lets a reader look for themselves; asserting a relationship between them is the thing
/// this app does not do.
struct ReportTracePoint: Hashable, Sendable, Identifiable {

    /// Start of the day, in the calendar the report was built with.
    let day: Date

    /// Mean of every barometer reading recorded that day. `nil` when none was — the phone
    /// samples opportunistically, so a day with no reading is an ordinary outcome and the
    /// chart has to show a gap rather than interpolate one.
    let meanPressureHPa: Double?

    /// Highest intensity reported that day, matching `HistoryDay.peakIntensity` — the peak
    /// rather than the mean, for the reason stated there: averaging hides the day the reader
    /// opened the document to find.
    let peakIntensity: CheckInIntensity?

    var id: Date { day }

    var isEmpty: Bool { meanPressureHPa == nil && peakIntensity == nil }
}

// MARK: - Tags

/// One tag as the document names it: the identity, and the name it carried when the report
/// was made.
///
/// Both, not just the name, because the two together are what the drawing side needs. A
/// seeded tag the user never renamed is app copy and has to be looked up in the reader's
/// language — `WellbeingTag.label` decides that from exactly this pair — while a tag the user
/// wrote is their own words and is printed verbatim. Carrying only the name would put
/// "Headache" into a Ukrainian document; carrying only the identity would lose the user's own
/// text entirely.
///
/// The name is copied rather than read back at draw time. A report describes a stretch of time
/// that has already passed, and renaming a tag afterwards must not silently relabel a PDF that
/// was shared last week.
struct ReportTagRef: Hashable, Sendable, Identifiable {
    let id: WellbeingTag.ID
    let name: String
}

/// One tag and how many check-ins in the window carried it.
struct ReportTagCount: Hashable, Sendable, Identifiable {

    let tag: ReportTagRef
    let count: Int

    var id: WellbeingTag.ID { tag.id }
}

// MARK: - Entries

/// One check-in as the report prints it.
///
/// Flattened out of `CheckIn` on purpose: tag identities are already resolved to names, and
/// the fields the document does not print are simply not here. A view that cannot reach the
/// stored row cannot accidentally put something in the file that was never meant to leave.
struct ReportEntry: Hashable, Sendable, Identifiable {

    let id: UUID
    let timestamp: Date
    let intensity: CheckInIntensity

    /// Ordered by `ReportBuilder`, because `CheckIn.tagIDs` is a `Set` and carries no order of
    /// its own — without one, the same check-in prints its tags differently on every
    /// generation and two PDFs of the same period stop being comparable.
    let tags: [ReportTagRef]

    let medications: [MedicationEntry]

    /// The user's own words, cut to `noteCharacterLimit`.
    ///
    /// Included because the report exists to be handed to someone the user chose, and their
    /// own written account of a harder day is the part of the log a reader can least
    /// reconstruct from the numbers. `CheckIn.note` is barred from *outbound payloads* — the
    /// network egress rule in `CLAUDE.md` — and this file is not one: it is generated on the
    /// device and moves only when the user shares it themselves.
    let note: String?

    /// Whether `note` was cut, so the document can say so rather than quietly ending a
    /// sentence mid-word.
    let isNoteTruncated: Bool
}

extension ReportEntry {

    /// Longest note the document prints, in characters.
    ///
    /// A bound at all because `note` is unbounded free text and a PDF page cannot scroll: one
    /// long entry would otherwise be taller than the page it has to fit on, and there is no
    /// layout that recovers from that. 280 is roughly four printed lines at the document's
    /// body size — enough for the sentence or two people actually write, and short enough that
    /// a page of entries stays a page. The full text stays in the app.
    ///
    /// Counted in `Character`s so a cut lands where a reader would say it does — the same rule
    /// `WellbeingTag.storedName(from:)` follows.
    static let noteCharacterLimit = 280

    /// `raw` as the document prints it, and whether anything was dropped.
    static func printableNote(from raw: String?) -> (text: String?, isTruncated: Bool) {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return (nil, false) }

        guard trimmed.count > noteCharacterLimit else { return (trimmed, false) }

        let cut = String(trimmed.prefix(noteCharacterLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cut, true)
    }
}

// MARK: - Sources

/// One line of the "Data sources" block: what the document was built from, and how much of it
/// there was.
///
/// The block exists so a reader can tell a quiet period from a period the app was not
/// recording in. Those look identical on the chart and mean entirely different things.
struct ReportSource: Hashable, Sendable, Identifiable {

    /// Which store the count came from. `String`-backed so the order below is also the order
    /// the block prints, and so a case cannot be added without deciding where it goes.
    enum Kind: String, CaseIterable, Sendable {
        case checkIns
        case medications
        case barometer
        case appleHealth
    }

    let kind: Kind

    /// Rows found in the window.
    ///
    /// Named for what it counts rather than plain `count`: a bare `count` compared against zero
    /// is what `empty_count` exists to catch, and the rule is right to be blunt about it even
    /// where — as here — the value is an `Int` with no `isEmpty` to prefer.
    let rowCount: Int

    var id: String { kind.rawValue }

    /// Whether the block draws this line as present. A source with nothing in it is still
    /// listed — leaving it out would hide exactly the fact the block exists to report.
    var isPresent: Bool { rowCount > 0 }
}
