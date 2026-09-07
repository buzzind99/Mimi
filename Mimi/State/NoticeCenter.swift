import Foundation
import Observation

/// Schedules a notice's auto-dismissal; injectable so tests fire (and cancel)
/// dismissals deterministically instead of sleeping. Returns a cancel
/// closure — invoked when the same notice re-fires (timer reset) or the
/// notice is dismissed before the delay elapses.
typealias NoticeScheduler = @Sendable (
    _ delay: Duration,
    _ fire: @escaping @MainActor () -> Void
) -> @Sendable () -> Void

/// State behind the transient notice pill (e.g. the copy confirmation).
/// Holds a single message at a time: re-posting replaces it in place and
/// resets the auto-dismiss timer instead of stacking duplicates. Owned by
/// `AppModel`; cleared on session stop/teardown.
@Observable
@MainActor
final class NoticeCenter {
    private(set) var message: String?

    /// Auto-dismiss delay (timer resets when the notice re-fires).
    static let autoDismissDelay: Duration = .seconds(2)

    private let scheduler: NoticeScheduler
    private var timer: (@Sendable () -> Void)?

    init(scheduler: @escaping NoticeScheduler = NoticeCenter.defaultScheduler) {
        self.scheduler = scheduler
    }

    /// Shows the message (replacing any visible one) and arms the timer.
    func post(message: String) {
        self.message = message
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
    }

    /// Real-time scheduler: sleeps off-main, then hops the dismissal to the
    /// main actor. Cancellation makes the sleep throw before firing.
    private static let defaultScheduler: NoticeScheduler = { delay, fire in
        let task = Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await MainActor.run { fire() }
        }
        return { task.cancel() }
    }
}
