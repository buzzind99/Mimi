import Foundation
import Observation

/// Schedules a toast's auto-dismissal; injectable so tests fire (and cancel)
/// dismissals deterministically instead of sleeping. Returns a cancel
/// closure — invoked when the same key re-fires (timer reset) or the toast
/// is dismissed/evicted before the delay elapses.
typealias ToastScheduler = @Sendable (
    _ delay: Duration,
    _ fire: @escaping @MainActor () -> Void
) -> @Sendable () -> Void

/// Toast keys wired by `AppModel` (one per error surface).
enum ToastKey {
    static let translationRetry = "translation.retry"
    static let translationFallback = "translation.fallback"
    static let translationUnavailable = "translation.unavailable"
    static let captureLost = "capture.lost"
    static let sessionFailed = "session.failed"
    static let asrWarning = "asr.warning"
    static let exportFailed = "export.failed"
}

/// State behind the toast stack. Posts are deduped by key — a repeat event
/// replaces the existing card in place and resets its auto-dismiss timer
/// instead of stacking a duplicate (retry progress and ASR warnings fire
/// repeatedly) — and the stack is capped at `maxVisible` cards, dropping the
/// oldest. Owned by `AppModel`; cleared on session stop/teardown.
@Observable
@MainActor
final class ToastCenter {
    /// The three toast classes: transient warnings auto-dismiss
    /// after 6 s; persistent cards stay until their condition clears and
    /// carry the fix action (red cards are always actionable).
    enum Style: Equatable, Sendable {
        case yellowAuto
        case yellowPersistent
        case redPersistent
    }

    struct Action: Equatable {
        let label: String
        let handler: @MainActor () -> Void

        /// Actions compare by label only; handlers are closures.
        static func == (lhs: Action, rhs: Action) -> Bool {
            lhs.label == rhs.label
        }
    }

    struct Toast: Identifiable, Equatable {
        /// Memberwise-settable so `post`'s dedup path can preserve the
        /// replaced card's identity: with a stable id, SwiftUI updates the
        /// existing card in place instead of playing a remove+insert
        /// transition for what is a content refresh of the same toast.
        var id = UUID()
        let key: String
        let style: Style
        let title: String
        let body: String
        let action: Action?
    }

    private(set) var toasts: [Toast] = []

    /// Auto-dismiss delay for `.yellowAuto` cards (timer resets when the
    /// same key re-fires).
    static let autoDismissDelay: Duration = .seconds(6)
    /// Stack cap; the oldest card is dropped beyond this.
    static let maxVisible = 3

    private let autoDismissAfter: Duration
    private let scheduler: ToastScheduler
    /// Live auto-dismiss timers by toast key (cancel closures).
    private var timers: [String: @Sendable () -> Void] = [:]

    init(
        autoDismissAfter: Duration = ToastCenter.autoDismissDelay,
        scheduler: @escaping ToastScheduler = ToastCenter.defaultScheduler
    ) {
        self.autoDismissAfter = autoDismissAfter
        self.scheduler = scheduler
    }

    /// Adds a toast (newest first), deduping by `key`: an existing card with
    /// the same key is replaced in place — keeping its `id` so SwiftUI treats
    /// it as a content update rather than a remove+insert — and its
    /// auto-dismiss timer reset.
    func post(
        key: String, style: Style, title: String, body: String, action: Action? = nil
    ) {
        let toast: Toast
        if let at = toasts.firstIndex(where: { $0.key == key }) {
            toast = Toast(
                id: toasts[at].id, key: key, style: style,
                title: title, body: body, action: action
            )
            toasts[at] = toast
        } else {
            toast = Toast(key: key, style: style, title: title, body: body, action: action)
            toasts.insert(toast, at: 0)
        }
        if toasts.count > Self.maxVisible {
            for overflow in toasts[Self.maxVisible...] {
                timers.removeValue(forKey: overflow.key)?()
            }
            toasts.removeSubrange(Self.maxVisible...)
        }
        scheduleAutoDismiss(of: toast)
    }

    /// Removes the card with the given key (condition cleared).
    func dismiss(key: String) {
        timers.removeValue(forKey: key)?()
        toasts.removeAll { $0.key == key }
    }

    /// Clears the whole stack (session stop/teardown).
    func clearAll() {
        for cancel in timers.values {
            cancel()
        }
        timers.removeAll()
        toasts.removeAll()
    }

    /// Arms the auto-dismiss timer for `.yellowAuto` cards. Dismissal is
    /// keyed on the toast's `id`; the guard is defense-in-depth — the timer
    /// is always cancelled before a replacement is scheduled, so a stale
    /// firing should not occur, and with the replaced card's id preserved a
    /// late fire would simply be a correct dismissal.
    private func scheduleAutoDismiss(of toast: Toast) {
        timers.removeValue(forKey: toast.key)?()
        guard toast.style == .yellowAuto else { return }
        timers[toast.key] = scheduler(autoDismissAfter) { [weak self] in
            self?.dismiss(id: toast.id)
        }
    }

    private func dismiss(id: UUID) {
        guard let at = toasts.firstIndex(where: { $0.id == id }) else { return }
        timers.removeValue(forKey: toasts[at].key)
        toasts.remove(at: at)
    }

    /// Real-time scheduler: sleeps off-main, then hops the dismissal to the
    /// main actor. Cancellation makes the sleep throw before firing.
    private static let defaultScheduler: ToastScheduler = { delay, fire in
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
