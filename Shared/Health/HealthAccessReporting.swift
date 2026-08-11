import Foundation

/// How far the Apple Health connection has got, as far as iOS is willing to say.
///
/// **This is a request state, not a grant state.** iOS deliberately never reveals whether
/// a *read* type was allowed or refused — an unauthorised read returns an empty result,
/// indistinguishable from an empty Health store
/// (`.claude/skills/healthkit_permissions/SKILL.md`). The only authorisation fact the
/// system exposes for a read set is `HKAuthorizationRequestStatus`: whether asking again
/// would put a sheet on screen. That is what these cases carry, and nothing here may be
/// presented as "granted".
///
/// Whether readings are actually arriving is a separate question with a separate answer —
/// the training log — because the two can disagree in both directions and collapsing them
/// into one boolean would state a denial the app cannot observe.
enum HealthAccessState: Equatable, Sendable {

    /// The device has no Health store — iPad without Health, or a Mac. Nothing to connect
    /// to, so the row is inert rather than merely off.
    case unavailable

    /// At least one type in the read set has never been put in front of the user. Asking
    /// shows the sheet, so the row is actionable.
    case notRequested

    /// The user has answered the sheet for every type Barosense reads. Says nothing about
    /// what they answered; asking again would show nothing, so from here the only way to
    /// change anything is the Health app.
    case requested

    /// Whether the user still has an answer to give. Drives whether tapping the row opens
    /// the sheet or sends them to the Health app.
    var canPresentSheet: Bool { self == .notRequested }
}

/// The Apple Health connection as the Settings screen is allowed to see it.
///
/// Declared next to its consumer rather than folded into `HealthDataReader`: the reader's
/// job is samples, and its `requestAuthorization` contract is explicitly "you may not
/// branch on the outcome". This protocol answers a different question — has the user been
/// asked yet — which is the one thing about a read set iOS does answer.
protocol HealthAccessReporting: Sendable {

    /// Current state. Cheap enough to call on every appearance of the screen: it is one
    /// XPC round trip and touches no sample data.
    func accessState() async -> HealthAccessState

    /// Presents the Health sheet for the read set.
    ///
    /// Returning normally means the sheet was handled, not that anything was granted.
    /// Callers re-read `accessState()` afterwards, which will have moved to `.requested`
    /// either way.
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
