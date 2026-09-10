import Foundation
import Observation

/// State behind the transient notice pill (e.g. the copy confirmation).
/// Holds a single message at a time: re-posting replaces it in place and
/// resets the auto-dismiss timer instead of stacking duplicates. Owned by
/// `AppModel`; cleared on session stop/teardown.
@Observable
@MainActor
final class NoticeCenter {
    /// Pill tones: `.confirm` (copy confirmation, teal) and `.warning`
    /// (dictionary no-hit, amber). The pill paints both from the tone.
    enum NoticeTone: Equatable, Sendable {
        case confirm
        case warning
    }

    private(set) var message: String?
    /// Tone of the visible notice; drives the pill's color tokens. Resets
    /// with the message on dismissal.
    private(set) var tone: NoticeTone = .confirm

    /// Auto-dismiss delay (timer resets when the notice re-fires).
    static let autoDismissDelay: Duration = .seconds(2)

    private let scheduler: AutoDismissScheduler
    private var timer: (@Sendable () -> Void)?

    init(scheduler: @escaping AutoDismissScheduler = AutoDismiss.timerScheduler) {
        self.scheduler = scheduler
    }

    /// Shows the message (replacing any visible one) and arms the timer.
    /// The tone travels with the message so a re-post replaces both in
    /// place.
    func post(message: String, tone: NoticeTone = .confirm) {
        self.message = message
        self.tone = tone
        timer?()
        timer = scheduler(Self.autoDismissDelay) { [weak self] in
            self?.dismiss()
        }
    }

    /// Removes the notice (auto-dismiss or session stop/teardown).
    func dismiss() {
        timer?()
        timer = nil
        message = nil
        tone = .confirm
    }
}
