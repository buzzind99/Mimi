import Foundation
@testable import Mimi
import Testing

/// Tests `ToastCenter`: post/dedup-by-key semantics (replace in place +
/// auto-dismiss timer reset), the injectable scheduler driving the 6 s
/// auto-dismiss (yellow cards only), the ~3-card stack cap (oldest dropped),
/// and dismissal/clearing.
///
/// The manual scheduler records every scheduled firing with a cancellable
/// token; tests fire pending timers deterministically instead of sleeping.
@MainActor
@Suite("ToastCenter")
struct ToastCenterTests {

    // MARK: - Fixtures

    private func makeSUT(scheduler: ManualScheduler) -> ToastCenter {
        ToastCenter(scheduler: { delay, fire in scheduler.schedule(delay, fire) })
    }

    // MARK: - Post

    @Test("posting stacks newest first")
    func postStacksNewestFirst() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(key: "a", style: .yellowAuto, title: "A", body: "first")
        center.post(key: "b", style: .yellowAuto, title: "B", body: "second")

        #expect(center.toasts.map(\.key) == ["b", "a"])
    }

    @Test("reposting the same key replaces the card in place")
    func repostReplacesInPlace() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(key: "a", style: .yellowAuto, title: "A", body: "first")
        center.post(key: "b", style: .yellowAuto, title: "B", body: "second")
        center.post(key: "a", style: .yellowAuto, title: "A", body: "updated")

        #expect(center.toasts.map(\.key) == ["b", "a"], "the replaced card keeps its position")
        #expect(center.toasts.last?.body == "updated")
    }

    @Test("reposting carries an action through the replacement")
    func repostCarriesAction() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(key: "a", style: .redPersistent, title: "A", body: "first")
        center.post(
            key: "a", style: .redPersistent, title: "A", body: "updated",
            action: .init(label: "Retry") {}
        )

        #expect(center.toasts.count == 1)
        #expect(center.toasts[0].action?.label == "Retry")
    }

    /// The replaced card keeps its `id` so SwiftUI updates the existing card
    /// in place instead of playing a remove+insert transition (new id would
    /// read as a different card to the stack's `ForEach`).
    @Test("reposting preserves the card's identity")
    func repostPreservesIdentity() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(key: "a", style: .yellowAuto, title: "A", body: "first")
        let originalID = center.toasts[0].id

        center.post(key: "a", style: .yellowAuto, title: "A", body: "updated")
        #expect(center.toasts[0].id == originalID, "the replacement reuses the card's id")

        center.dismiss(key: "a")
        center.post(key: "a", style: .yellowAuto, title: "A", body: "fresh")
        #expect(center.toasts[0].id != originalID, "a fresh post after dismissal gets a new id")
    }

    // MARK: - Auto-dismiss

    @Test("a yellowAuto toast schedules its 6 s auto-dismiss and fires it")
    func yellowAutoAutoDismisses() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(key: "a", style: .yellowAuto, title: "A", body: "transient")

        #expect(spy.pendingCount == 1)
        #expect(spy.delays == [.seconds(6)])

        spy.firePending()

        #expect(center.toasts.isEmpty, "the timer dismissed the card")
    }

    @Test("persistent styles never schedule an auto-dismiss")
    func persistentStylesNeverAutoDismiss() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(key: "p", style: .yellowPersistent, title: "P", body: "stays")
        center.post(key: "r", style: .redPersistent, title: "R", body: "stays")

        #expect(spy.pendingCount == 0, "no timer was scheduled")

        spy.firePending()

        #expect(center.toasts.count == 2, "both cards survive")
    }

    @Test("a replace resets the timer: the old firing is cancelled")
    func replaceResetsTimer() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(key: "a", style: .yellowAuto, title: "A", body: "first")
        center.post(key: "a", style: .yellowAuto, title: "A", body: "second")

        #expect(spy.pendingCount == 1, "the stale timer was cancelled, one live firing remains")

        spy.firePending()

        #expect(center.toasts.isEmpty, "the replacement's timer dismissed it exactly once")
    }

    @Test("the auto-dismiss delay is injectable")
    func delayIsInjectable() {
        let spy = ManualScheduler()
        let center = ToastCenter(
            autoDismissAfter: .seconds(3),
            scheduler: { delay, fire in spy.schedule(delay, fire) }
        )

        center.post(key: "a", style: .yellowAuto, title: "A", body: "quick")

        #expect(spy.delays == [.seconds(3)])
    }

    // MARK: - Cap

    @Test("posting beyond the cap drops the oldest card")
    func capDropsOldest() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        for key in ["a", "b", "c", "d"] {
            center.post(key: key, style: .yellowAuto, title: key, body: key)
        }

        #expect(center.toasts.map(\.key) == ["d", "c", "b"], "the oldest (a) was dropped")
        #expect(spy.pendingCount == 3, "the dropped card's timer was cancelled too")
    }

    // MARK: - dismiss / clearAll

    @Test("dismiss removes the card with the key and cancels its timer")
    func dismissRemovesAndCancels() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(key: "a", style: .yellowAuto, title: "A", body: "transient")
        center.dismiss(key: "a")

        #expect(center.toasts.isEmpty)
        #expect(spy.pendingCount == 0, "the timer was cancelled")

        spy.firePending()

        #expect(center.toasts.isEmpty)
    }

    @Test("dismiss with an unknown key is a no-op")
    func dismissUnknownKeyIsNoOp() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(key: "a", style: .yellowAuto, title: "A", body: "stays")

        center.dismiss(key: "missing")

        #expect(center.toasts.count == 1)
    }

    @Test("clearAll empties the stack and cancels every timer")
    func clearAllEmptiesAndCancels() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(key: "a", style: .yellowAuto, title: "A", body: "one")
        center.post(key: "b", style: .redPersistent, title: "B", body: "two")
        center.clearAll()

        #expect(center.toasts.isEmpty)
        #expect(spy.pendingCount == 0)
    }
}

// MARK: - Manual scheduler fixtures

/// A scheduled firing; cancelled via the closure `schedule` returns.
private final class ManualTimerToken: @unchecked Sendable {
    let fire: @MainActor () -> Void
    var cancelled = false

    init(fire: @escaping @MainActor () -> Void) {
        self.fire = fire
    }
}

/// Deterministic toast scheduler: records every scheduled firing with a
/// cancellable token; tests fire pending dismissals instead of sleeping.
private final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: [ManualTimerToken] = []

    var delays: [Duration] = []

    func schedule(
        _ delay: Duration, _ fire: @escaping @MainActor () -> Void
    ) -> @Sendable () -> Void {
        let token = ManualTimerToken(fire: fire)
        lock.lock()
        scheduled.append(token)
        delays.append(delay)
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            token.cancelled = true
            self.lock.unlock()
        }
    }

    /// Live (uncancelled) firings, in schedule order.
    private var live: [ManualTimerToken] {
        lock.withLock { scheduled.filter { !$0.cancelled } }
    }

    var pendingCount: Int {
        live.count
    }

    /// Fires every live dismissal and forgets the schedule. MainActor: the
    /// stored `fire` closures are, and every caller (the tests) is too.
    @MainActor
    func firePending() {
        let tokens = live
        lock.withLock { scheduled.removeAll() }
        for token in tokens {
            token.fire()
        }
    }
}
