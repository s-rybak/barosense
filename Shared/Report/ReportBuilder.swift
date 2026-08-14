import Foundation

/// Turns what the stores hold into the one value the document draws.
///
/// Pure, synchronous, and free of every dependency the app has: no store, no clock of its
/// own, no view. The document is the part of this app another person reads, so what goes into
/// it has to be checkable from a test with a handful of literals rather than by generating a
/// PDF and looking at it.
///
/// Every function takes the `Calendar` it should work in. Day boundaries decide which entries
/// land on which line of the chart, and a builder reaching for `.current` would pass under one
/// time zone and fail under another.
enum ReportBuilder {

    /// Assembles the report.
    ///
    /// `checkIns` and `pressureSamples` are expected to be the window's contents as the stores
    /// returned them; anything outside is filtered out here anyway, so a caller that reads a
    /// slightly wider range does not corrupt the totals.
    ///
    /// `healthReadingCount` is a count rather than the samples themselves. The document prints
    /// how much Health data backed the period and nothing else about it, and reading a year of
    /// sleep intervals into memory to produce one integer is a cost with no reader.
    ///
    /// `tagsByID` should carry archived tags too. A check-in from March can hold a tag retired
    /// in April, and the document still has to be able to name it.
    static func make(period: ReportPeriod,
                     window: Range<Date>,
                     generatedAt: Date,
                     profile: UserProfile?,
                     checkIns: [CheckIn],
                     pressureSamples: [PressureSample],
                     healthReadingCount: Int,
                     tagsByID: [WellbeingTag.ID: WellbeingTag],
                     calendar: Calendar = .current) -> WellbeingReport {

        let inWindow = checkIns
            .filter { window.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }

        let pressureInWindow = pressureSamples.filter { window.contains($0.timestamp) }
        let medicationEntries = inWindow.flatMap(\.medications)

        let totals = ReportTotals(
            checkInCount: inWindow.count,
            daysWithEntries: Set(inWindow.map { calendar.startOfDay(for: $0.timestamp) }).count,
            medicationEntryCount: medicationEntries.count,
            pressureReadingCount: pressureInWindow.count,
            healthReadingCount: healthReadingCount
        )

        return WellbeingReport(
            period: period,
            window: window,
            // The upper bound is the start of the day *after* the last one covered.
            lastCoveredDay: lastCoveredDay(of: window, calendar: calendar),
            generatedAt: generatedAt,
            profile: ReportProfile(displayName: profile?.displayName,
                                   ageYears: profile?.ageYears,
                                   gender: profile?.gender),
            totals: totals,
            intensity: ReportIntensityDigest(checkIns: inWindow),
            trace: trace(window: window,
                         checkIns: inWindow,
                         pressureSamples: pressureInWindow,
                         calendar: calendar),
            tags: tagCounts(in: inWindow, tagsByID: tagsByID),
            medications: MedicationHistory.summaries(in: medicationEntries),
            // Newest first: a reader opening the log wants the most recent day at the top,
            // which is the opposite of the ascending order every feature-facing read uses.
            entries: inWindow.reversed().map { entry($0, tagsByID: tagsByID) },
            sources: sources(totals: totals)
        )
    }

    // MARK: - Chart

    /// One point per day of the window, in order, gaps included.
    ///
    /// Every day is emitted whether or not anything was recorded in it. A chart built only
    /// from occupied days draws a straight line between two readings a fortnight apart and
    /// claims a fortnight of coverage that does not exist — the same reason
    /// `PressureSeries.timeDomain` is fixed by the range rather than by the data.
    static func trace(window: Range<Date>,
                      checkIns: [CheckIn],
                      pressureSamples: [PressureSample],
                      calendar: Calendar = .current) -> [ReportTracePoint] {

        let pressureByDay = Dictionary(grouping: pressureSamples) {
            calendar.startOfDay(for: $0.timestamp)
        }
        let checkInsByDay = Dictionary(grouping: checkIns) {
            calendar.startOfDay(for: $0.timestamp)
        }

        var points: [ReportTracePoint] = []
        var day = calendar.startOfDay(for: window.lowerBound)

        while day < window.upperBound {
            points.append(ReportTracePoint(
                day: day,
                meanPressureHPa: pressureByDay[day].map(meanHectopascals),
                peakIntensity: checkInsByDay[day]?.map(\.intensity).max()
            ))

            // A calendar that will not advance a day would otherwise spin here forever.
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else {
                break
            }
            day = next
        }

        return points
    }

    private static func meanHectopascals(_ samples: [PressureSample]) -> Double {
        samples.reduce(0) { $0 + $1.pressure.hectopascals } / Double(samples.count)
    }

    // MARK: - Tags

    /// Most-used first, names resolved as they stand now.
    ///
    /// A tag the vocabulary can no longer name is left out rather than printed under a
    /// placeholder. The store archives tags instead of deleting them, so an unresolvable
    /// identity means the check-in outlived its tag through a path that does not exist today;
    /// a blank row in a document someone else reads is worse than one row fewer.
    static func tagCounts(in checkIns: [CheckIn],
                          tagsByID: [WellbeingTag.ID: WellbeingTag]) -> [ReportTagCount] {
        var counts: [WellbeingTag.ID: Int] = [:]
        for checkIn in checkIns {
            for tagID in checkIn.tagIDs where tagsByID[tagID] != nil {
                counts[tagID, default: 0] += 1
            }
        }

        return counts
            .compactMap { id, count in
                tagsByID[id].map {
                    ReportTagCount(tag: ReportTagRef(id: id, name: $0.name), count: count)
                }
            }
            // Ties broken on the stored name, so two tags used equally often keep the same
            // order between two generations of the same period. Deliberately the *stored*
            // name rather than the drawn one: an unrenamed seeded tag is drawn through a
            // translation table, and ordering on that would reshuffle the block when the
            // reader switches language — a document should not rearrange itself.
            .sorted { lhs, rhs in
                lhs.count == rhs.count
                    ? lhs.tag.name.localizedStandardCompare(rhs.tag.name) == .orderedAscending
                    : lhs.count > rhs.count
            }
    }

    // MARK: - Entries

    private static func entry(_ checkIn: CheckIn,
                              tagsByID: [WellbeingTag.ID: WellbeingTag]) -> ReportEntry {
        let note = ReportEntry.printableNote(from: checkIn.note)

        return ReportEntry(
            id: checkIn.id,
            timestamp: checkIn.timestamp,
            intensity: checkIn.intensity,
            // Sorted on the stored name for the reason `tagCounts(in:tagsByID:)` gives: it is
            // an order, not a ranking, and it must not move when the reader's language does.
            tags: checkIn.tagIDs
                .compactMap { id in tagsByID[id].map { ReportTagRef(id: id, name: $0.name) } }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            medications: checkIn.medications.sorted { $0.takenAt < $1.takenAt },
            note: note.text,
            isNoteTruncated: note.isTruncated
        )
    }

    // MARK: - Sources

    /// The "Data sources" block, in `ReportSource.Kind`'s declaration order.
    ///
    /// All four are always listed, empty ones included. A source with nothing in it is the one
    /// thing the block exists to show: on the chart, a period the app was not recording in and
    /// a period the user simply felt fine in look identical.
    static func sources(totals: ReportTotals) -> [ReportSource] {
        ReportSource.Kind.allCases.map { kind in
            switch kind {
            case .checkIns: ReportSource(kind: kind, count: totals.checkInCount)
            case .medications: ReportSource(kind: kind, count: totals.medicationEntryCount)
            case .barometer: ReportSource(kind: kind, count: totals.pressureReadingCount)
            case .appleHealth: ReportSource(kind: kind, count: totals.healthReadingCount)
            }
        }
    }

    // MARK: - Dates

    /// The last day `window` actually covers. Its upper bound is the start of the next day, so
    /// formatting the bound itself would name a day the report excludes.
    private static func lastCoveredDay(of window: Range<Date>, calendar: Calendar) -> Date {
        calendar.startOfDay(for: window.upperBound.addingTimeInterval(-1))
    }
}
