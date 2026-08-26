import Foundation
import Observation

/// What the watch's quick check-in holds while it is being filled in.
///
/// Separate from the view for the reason every model in this project is: the rules — which
/// values are reachable, when the action is live, what happens on a failed hand-off — are
/// assertable, and a `body` is not.
///
/// ## Why this one is in `Shared/` when `LogModel` is not
///
/// `SharedTests` links the iOS app, so the phone's models are already reachable from a test
/// where they sit. Nothing links `BarosenseWatch/`, so a model left in there is a model with
/// no way to be asserted on — and this one carries the whole of the watch's check-in
/// behaviour. It qualifies to be here: `Observation` is not a UI framework, and the words for
/// a failure stay in the view layer as a `LocalizedStringKey` extension on `WatchLogFailure`.
@MainActor
@Observable
final class WatchLogModel {

    /// Opens at the middle of the scale, matching the phone's form and the frame.
    ///
    /// **This biases the label**, and the bias is recorded on the phone's copy too
    /// (`LogModel.intensity`): a user who saves without touching the control records a 5 they
    /// did not choose, one point below the event threshold. The watch makes it slightly worse
    /// than the phone does, because a crown is easier to leave alone than a slider is. Same
    /// fix when it comes, in both places at once.
    var intensity = CheckInIntensity(clamping: 5)

    private(set) var selectedTagIDs: Set<WellbeingTag.ID> = []

    /// True once the check-in is on the queue. Terminal — the form does not accept a second
    /// one, it closes.
    private(set) var hasSaved = false

    private(set) var failure: WatchLogFailure?

    /// The vocabulary the phone published. Empty when the phone has not yet sent one, which
    /// is when the chips are simply absent: intensity is what makes a check-in, and a form
    /// with no tags is still a usable form.
    let tags: [WatchTag]

    private let link: any CheckInTransferLink
    private let now: @Sendable () -> Date

    init(tags: [WatchTag],
         link: any CheckInTransferLink,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.tags = tags
        self.link = link
        self.now = now
    }

    var canIncrease: Bool { intensity.rawValue < CheckInIntensity.scale.upperBound }
    var canDecrease: Bool { intensity.rawValue > CheckInIntensity.scale.lowerBound }

    /// Open until the check-in is on the queue, and closed after — the form does not accept
    /// a second report, it closes.
    ///
    /// It is deliberately not also gated on whether the link is usable; see
    /// `CheckInTransferLink.transfer` for why a failed hand-off is reported rather than
    /// pre-empted. A failure leaves this `true`, so the user's input is still on screen and
    /// the action is still live to try again.
    var canSave: Bool { !hasSaved }

    func increase() {
        intensity = CheckInIntensity(clamping: intensity.rawValue + 1)
    }

    func decrease() {
        intensity = CheckInIntensity(clamping: intensity.rawValue - 1)
    }

    func toggle(_ id: WellbeingTag.ID) {
        if selectedTagIDs.contains(id) {
            selectedTagIDs.remove(id)
        } else {
            selectedTagIDs.insert(id)
        }
    }

    /// Stamped with the watch's clock at the moment the user commits, not with the instant
    /// the phone receives it — which can be hours later. A check-in filed against the wrong
    /// weather is worse than no check-in.
    func save() {
        guard canSave else { return }

        failure = nil

        let checkIn = WatchCheckIn(timestamp: now(),
                                   intensity: intensity,
                                   tagIDs: selectedTagIDs)
        do {
            try link.transfer(checkIn)
            hasSaved = true
        } catch {
            failure = .couldNotQueue
        }
    }
}

enum WatchLogFailure: Equatable {

    /// The session would not take the item. The user is told plainly rather than shown a
    /// confirmation for something that did not happen.
    case couldNotQueue
}
