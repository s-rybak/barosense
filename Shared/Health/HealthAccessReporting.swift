import Foundation

/// What Barosense can actually read from the Health store.
///
/// **iOS never reports a read *grant*.** An unauthorised read returns an empty result,
/// indistinguishable from an empty Health store
/// (`.claude/skills/healthkit_permissions/SKILL.md`), and `authorizationStatus(for:)` is
/// meaningful only for share types. So the state is assembled from the two things that
/// *are* observable:
///
/// - `HKAuthorizationRequestStatus` — whether asking again would put a sheet on screen.
///   That is the whole of `.notRequested` vs `.requested`.
/// - A probe read per type. One sample coming back is **proof** the type is readable;
///   nothing coming back proves nothing at all.
///
/// The asymmetry is the point: `readable` is a set of proven grants, never a set of
/// inferred refusals. A type outside it is unproven, and no copy built on this may say
/// "denied".
///
/// It also bounds what may be *required*. An unproven type is only worth holding the user
/// to when a working device would have produced one — see `isFullyReadable`.
enum HealthAccessState: Equatable, Sendable {

    /// The device has no Health store — iPad without Health, or a Mac. Nothing to connect
    /// to, so the row is inert rather than merely off.
    case unavailable

    /// At least one type in the read set has never been put in front of the user. Asking
    /// shows the sheet, so the row is actionable.
    case notRequested

    /// The user has answered the sheet for every type Barosense reads.
    ///
    /// `readable` holds the types a probe read actually returned data for. It is empty for
    /// a user who refused everything *and* for one who allowed everything but has an empty
    /// Health store; the two are the same fact from here.
    case requested(readable: Set<HealthMetricKind>)

    /// Whether the user still has an answer to give. Drives whether tapping the row opens
    /// the sheet or sends them to the Health app.
    var canPresentSheet: Bool { self == .notRequested }

    /// Nothing Barosense can act on is missing.
    ///
    /// This is what the Settings switch shows, and it is deliberately not
    /// `allCases.allSatisfy`. Blood oxygen is excluded because its absence is a missing
    /// sensor at least as often as a missing grant
    /// (`HealthMetricKind.isOptionalOnSomeDevices`), and holding the switch off for it
    /// strands the user in a loop: the caption sends them to the Health app, everything
    /// there is already allowed, they come back, and the switch is still off. That is the
    /// re-prompt loop `.claude/skills/healthkit_permissions/SKILL.md` forbids, performed
    /// by hand.
    ///
    /// A sheet answered with a refusal leaves nothing readable, which fails the check on
    /// the types that remain: being asked is not being granted.
    ///
    /// Blood oxygen stays in the read set and in the log. It is only barred from being
    /// read as evidence about the user's answer, which it never was.
    var isFullyReadable: Bool {
        guard case .requested(let readable) = self else { return false }

        let expected = HealthMetricKind.expectedOnEveryDevice
        // `allSatisfy` over an empty expectation is vacuously true. The guard is on the
        // expectation rather than on `readable` — a refusal already fails the line below —
        // so that a read set in which every kind became hardware-optional cannot turn the
        // switch on for a user who granted nothing.
        guard !expected.isEmpty else { return false }

        return expected.allSatisfy(readable.contains)
    }

    /// The types a probe read returned nothing for, in `allCases` order so the caption
    /// they feed does not reshuffle between two reads of the same state.
    ///
    /// Not the same question as `isFullyReadable`, and deliberately wider: blood oxygen
    /// belongs here whenever it came back empty, including on a device where that is the
    /// missing sensor and the switch is on. This says what was observed; the switch says
    /// what is worth acting on.
    ///
    /// Empty before the sheet has been answered: nothing is unreadable yet, it is simply
    /// unasked, and listing every type there would read as a fault.
    var unreadableTypes: [HealthMetricKind] {
        guard case .requested(let readable) = self else { return [] }
        return HealthMetricKind.allCases.filter { !readable.contains($0) }
    }
}

/// The Apple Health connection as the Settings screen is allowed to see it.
///
/// Declared next to its consumer rather than folded into `HealthDataReader`: the reader's
/// job is samples, and its `requestAuthorization` contract is explicitly "you may not
/// branch on the outcome". This protocol answers the different question the switch needs —
/// has the user been asked, and what can Barosense demonstrably read.
protocol HealthAccessReporting: Sendable {

    /// Current state.
    ///
    /// Costs one authorisation-status round trip, plus — only once the sheet has been
    /// answered — one `limit: 1` sample query per type in the read set. One indexed
    /// existence check each, no sample data pulled into memory, on a screen the user opens
    /// by hand. Cheap enough for every appearance; not cheap enough for a timer.
    func accessState() async -> HealthAccessState

    /// Presents the Health sheet for the read set.
    ///
    /// Returning normally means the sheet was handled, not that anything was granted.
    /// Callers re-read `accessState()` afterwards, which is the only way to find out
    /// whether anything actually became readable.
    func requestAccess() async throws
}

/// `HealthAccessReporting` for a device with no Health store — previews, the simulator
/// before Health is set up, and tests that must not touch HealthKit.
struct UnavailableHealthAccessReporter: HealthAccessReporting {

    func accessState() async -> HealthAccessState { .unavailable }

    func requestAccess() async throws {
        throw HealthDataError.healthDataUnavailable
    }
}
