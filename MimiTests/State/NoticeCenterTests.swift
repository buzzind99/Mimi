import Foundation
@testable import Mimi
import Testing

/// Tests `NoticeCenter`: posting shows the message, the injectable scheduler
/// drives the 2 s auto-dismiss, re-posting resets the timer, and
/// dismissal/clearing.
///
/// The manual scheduler records every scheduled firing with a cancellable
/// token; tests fire pending timers deterministically instead of sleeping.
@MainActor
@Suite("NoticeCenter")
struct NoticeCenterTests {

    // MARK: - Fixtures

    private func makeSUT(scheduler: ManualScheduler) -> NoticeCenter {
        NoticeCenter(scheduler: { delay, fire in scheduler.schedule(delay, fire) })
    }

    // MARK: - Post

    @Test("posting shows the message")
    func postShowsMessage() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(message: "Text copied")

        #expect(center.message == "Text copied")
    }

    @Test("reposting replaces the message in place")
    func repostReplacesInPlace() {
        let center = makeSUT(scheduler: ManualScheduler())

        center.post(message: "first")
        center.post(message: "second")

        #expect(center.message == "second", "a single notice is held at a time")
    }

    // MARK: - Auto-dismiss

    @Test("a post schedules its 2 s auto-dismiss and fires it")
    func postAutoDismisses() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(message: "Text copied")

        #expect(spy.pendingCount == 1)
        #expect(spy.delays == [.seconds(2)])

        spy.firePending()

        #expect(center.message == nil, "the timer dismissed the notice")
    }

    @Test("a repost resets the timer: the old firing is cancelled")
    func repostResetsTimer() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(message: "first")
        center.post(message: "second")

        #expect(spy.pendingCount == 1, "the stale timer was cancelled, one live firing remains")

        spy.firePending()

        #expect(center.message == nil, "the replacement's timer dismissed it exactly once")
    }

    // MARK: - dismiss

    @Test("dismiss clears the message and cancels the timer")
    func dismissClearsAndCancels() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.post(message: "Text copied")
        center.dismiss()

        #expect(center.message == nil)
        #expect(spy.pendingCount == 0, "the timer was cancelled")

        spy.firePending()

        #expect(center.message == nil)
    }

    @Test("dismiss without a visible notice is a no-op")
    func dismissWithoutNoticeIsNoOp() {
        let spy = ManualScheduler()
        let center = makeSUT(scheduler: spy)

        center.dismiss()

        #expect(center.message == nil)
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

/// Deterministic notice scheduler: records every scheduled firing with a
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
