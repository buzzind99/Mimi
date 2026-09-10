import Foundation

/// Schedules a transient surface's auto-dismissal; injectable so tests fire
/// (and cancel) dismissals deterministically instead of sleeping. Returns a
/// cancel closure — invoked when the same surface re-fires (timer reset) or
/// is dismissed/evicted before the delay elapses.
typealias AutoDismissScheduler = @Sendable (
    _ delay: Duration,
    _ fire: @escaping @MainActor () -> Void
) -> @Sendable () -> Void

/// Namespace for the shipped `AutoDismissScheduler` implementations.
enum AutoDismiss {
    /// Real-time scheduler: sleeps off-main, then hops the dismissal to the
    /// main actor. Cancellation makes the sleep throw before firing.
    static let timerScheduler: AutoDismissScheduler = { delay, fire in
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
