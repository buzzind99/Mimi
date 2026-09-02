import Foundation
@testable import Mimi
import Testing
@preconcurrency import Translation

/// Tests `TranslationQueue` handler wiring, cache-hit enqueue, retry reset,
/// and drain bounds. The delivery paths run against the real OS ja→en pack
/// via `TranslationSession(installedSource:)` (macOS 26+ with the pack
/// installed; the session factories `try Test.cancel` otherwise over the
/// shared `TestEnvironment` probes) so the enqueue cache can be seeded
/// through the handler loop.
///
/// Swift Testing confirmations have no timeout, so every wait inside a
/// confirmation scope is bounded by `waitUntil(timeout:)` — on timeout the
/// scope exits un-confirmed and the confirmation records the issue instead
/// of hanging.
@MainActor
@Suite("TranslationQueue")
struct TranslationQueueTests {

    // MARK: - Fixtures

    private let sentenceText = "テスト"
    private let otherSentenceText = "こんにちは"
    /// First translate loads the pack model; generous for slow machines.
    private let resultTimeout: TimeInterval = 20

    // MARK: - Helpers

    private func makeSUT() -> (queue: TranslationQueue, sink: QueueSink) {
        let sink = QueueSink()
        let queue = TranslationQueue()
        return (queue, sink)
    }

    private func makeSentence(index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
    }

    /// Bounded poll for a condition. Confirmation scopes rely on this for
    /// termination: it gives up after `timeout`, leaving the confirmation
    /// un-fulfilled so the scope exit records the issue.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Real session for the installed ja→en pair. `translate` runs locally once
    /// the pack is present (no prompts); cancelled otherwise so the suite stays
    /// green on machines without the pack.
    private func makeInstalledJAToENSession() async throws -> TranslationSession {
        guard #available(macOS 26.0, *) else {
            try Test.cancel("TranslationSession(installedSource:) requires macOS 26")
        }
        guard await TestEnvironment.jaToENPackInstalled() else {
            try Test.cancel("ja→en translation pack is not installed")
        }
        let source = Locale.Language(identifier: "ja")
        let target = Locale.Language(identifier: "en")
        return TranslationSession(installedSource: source, target: target)
    }

    /// Session whose `translate` deterministically throws: target "zz" is
    /// unsupported, so the worker always lands in its error path. The
    /// non-throwing `init(installedSource:)` requires the source pack to exist,
    /// so the installed ja→en pair gates it as a proxy for "ja pack present".
    private func makeUnsupportedTargetSession() async throws -> TranslationSession {
        guard #available(macOS 26.0, *) else {
            try Test.cancel("TranslationSession(installedSource:) requires macOS 26")
        }
        guard await TestEnvironment.jaToENPackInstalled() else {
            try Test.cancel("ja translation pack is not installed")
        }
        let source = Locale.Language(identifier: "ja")
        return TranslationSession(installedSource: source, target: Locale.Language(identifier: "zz"))
    }

    // MARK: - setHandlers

    @Test("the status handler observes status changes")
    func statusHandlerObservesChanges() {
        let (queue, sink) = makeSUT()
        // Result-handler wiring is exercised by the delivery tests below.
        queue.setHandlers(
            result: { _, _ in },
            status: { sink.receive(status: $0) }
        )

        queue.resetForRetry()

        #expect(sink.statuses == [.idle])
    }

    // MARK: - resetForRetry

    @Test("resetForRetry from idle republishes idle")
    func resetForRetryFromIdleRepublishesIdle() {
        let (queue, sink) = makeSUT()
        queue.setHandlers(
            result: { _, _ in },
            status: { sink.receive(status: $0) }
        )

        queue.resetForRetry()

        #expect(queue.status == .idle)
        #expect(sink.statuses == [.idle])
    }

    // MARK: - drain

    @Test("drain with nothing pending succeeds")
    func drainWithNothingPendingSucceeds() async {
        let queue = TranslationQueue()

        let drained = await queue.drain(timeout: 0.05)

        #expect(drained)
    }

    /// A sentence enqueued with no worker attached (no `run(with:)` yet) sits
    /// in `pending`, so a bounded drain must time out instead of completing.
    @Test("drain times out with pending work and no worker")
    func drainWithoutWorkerTimesOut() async {
        let queue = TranslationQueue()
        queue.enqueue(makeSentence(index: 0, text: sentenceText))

        let drained = await queue.drain(timeout: 0.05)

        #expect(!drained)
    }

    // MARK: - run(with:) single delivery + resetForRetry from non-idle

    @Test("a single enqueue is delivered through the status cycle")
    func singleEnqueueDeliversThroughStatusCycle() async throws {
        let session = try await makeInstalledJAToENSession()
        let (queue, sink) = makeSUT()
        await confirmation("translation delivered") { delivered in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                    delivered()
                },
                status: { sink.receive(status: $0) }
            )
            let worker = Task { await queue.run(with: session) }
            defer { worker.cancel() }

            queue.enqueue(makeSentence(index: 0, text: sentenceText))
            await waitUntil(timeout: resultTimeout) { sink.results.count == 1 }
        }

        let delivery = try #require(sink.results.first)
        #expect(sink.results.count == 1)
        #expect(delivery.index == 0)
        #expect(delivery.translation.lang == "en")
        #expect(!delivery.translation.text.isEmpty)
        #expect(sink.statuses == [.ready, .translating, .ready])

        // Retry reset also clears a non-idle (.ready) status.
        queue.resetForRetry()
        #expect(queue.status == .idle)
        #expect(sink.statuses == [.ready, .translating, .ready, .idle])
    }

    // MARK: - run(with:) wake loop

    /// Enqueues while the worker is already parked in the wake loop — the
    /// incremental path that keeps one session alive for follow-up sentences.
    @Test("an enqueue on an idle worker wakes the loop and delivers")
    func enqueueOnIdleWorkerWakesAndDelivers() async throws {
        let session = try await makeInstalledJAToENSession()
        let (queue, sink) = makeSUT()
        await confirmation("both translations delivered", expectedCount: 2) { delivered in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                    delivered()
                },
                status: { sink.receive(status: $0) }
            )
            let worker = Task { await queue.run(with: session) }
            defer { worker.cancel() }

            queue.enqueue(makeSentence(index: 0, text: sentenceText))
            await waitUntil(timeout: resultTimeout) { sink.results.count == 1 }
            // Wait for the worker to publish .ready again (batch done), so the
            // second enqueue lands on an idle worker and must wake it.
            await waitUntil(timeout: 5) { queue.status == .ready }
            #expect(queue.status == .ready)

            queue.enqueue(makeSentence(index: 1, text: otherSentenceText))
            await waitUntil(timeout: resultTimeout) { sink.results.count == 2 }
        }

        let second = try #require(sink.results.last)
        #expect(sink.results.count == 2)
        #expect(second.index == 1)
        #expect(second.translation.lang == "en")
        #expect(!second.translation.text.isEmpty)
        #expect(sink.statuses == [.ready, .translating, .ready, .translating, .ready])
    }

    // MARK: - enqueue cache hit

    /// Seeds the cache through the worker's delivery path, then re-enqueues the
    /// same text under a new index: the cached result must post synchronously
    /// at enqueue time and never enter `pending`.
    @Test("a repeat enqueue posts the cached result synchronously, bypassing pending")
    func cacheHitPostsSynchronouslyAndBypassesPending() async throws {
        let session = try await makeInstalledJAToENSession()
        let (queue, sink) = makeSUT()
        try await confirmation("results delivered", expectedCount: 1...) { delivered in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                    delivered()
                },
                status: { sink.receive(status: $0) }
            )
            let worker = Task { await queue.run(with: session) }
            defer { worker.cancel() }

            queue.enqueue(makeSentence(index: 0, text: sentenceText))
            await waitUntil(timeout: resultTimeout) { sink.results.count == 1 }
            let seed = try #require(sink.results.first).translation

            queue.enqueue(makeSentence(index: 5, text: sentenceText))

            #expect(sink.results.count == 2, "cache hit must post without awaiting")
            let cached = try #require(sink.results.last)
            #expect(cached.index == 5)
            #expect(cached.translation == seed)
            let drained = await queue.drain(timeout: 0.05)
            #expect(drained, "cache hit must bypass pending")
        }
    }

    // MARK: - run(with:) cancellation

    /// Cancelling the worker before its body runs makes `session.translate`
    /// throw `CancellationError` deterministically: the sentence must be
    /// re-queued for the next run and the status returned to `.idle`.
    @Test("a worker cancelled before starting re-queues the sentence and returns to idle")
    func cancelledBeforeStartRequeuesAndReturnsToIdle() async throws {
        let session = try await makeInstalledJAToENSession()
        let (queue, sink) = makeSUT()
        queue.setHandlers(
            result: { index, translation in
                sink.receive(index: index, translation: translation)
            },
            status: { sink.receive(status: $0) }
        )

        queue.enqueue(makeSentence(index: 0, text: sentenceText))

        let worker = Task { await queue.run(with: session) }
        worker.cancel()
        await worker.value

        #expect(sink.results.isEmpty)
        #expect(sink.statuses == [.ready, .translating, .idle])
        let drained = await queue.drain(timeout: 0.05)
        #expect(!drained, "cancelled work must be re-queued, not lost")
    }

    // MARK: - run(with:) batch delivery

    /// Both enqueues happen before the (main-actor) worker resumes, so the
    /// worker must translate them as one batched round-trip: one
    /// translating→ready cycle for two results, FIFO order preserved.
    @Test("a burst of enqueues is delivered as one batched round-trip, in order")
    func burstEnqueueDeliversAsSingleBatchInOrder() async throws {
        let session = try await makeInstalledJAToENSession()
        let (queue, sink) = makeSUT()
        await confirmation("batch delivered", expectedCount: 2) { delivered in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                    delivered()
                },
                status: { sink.receive(status: $0) }
            )
            let worker = Task { await queue.run(with: session) }
            defer { worker.cancel() }

            queue.enqueue(makeSentence(index: 0, text: sentenceText))
            queue.enqueue(makeSentence(index: 1, text: otherSentenceText))
            await waitUntil(timeout: resultTimeout) { sink.results.count == 2 }
        }

        #expect(sink.results.map { $0.index } == [0, 1])
        #expect(sink.statuses == [.ready, .translating, .ready], "one batched round-trip")
    }

    // MARK: - run(with:) failure path

    /// An unsupported target makes `translate` throw deterministically; the
    /// worker must re-queue the sentence, publish `.unavailable`, and exit —
    /// after which `drain` fails fast instead of waiting out its timeout.
    @Test("a translation failure publishes .unavailable and makes drain fail fast")
    func translationFailurePublishesUnavailableAndFailsDrainFast() async throws {
        let session = try await makeUnsupportedTargetSession()
        let (queue, sink) = makeSUT()
        await confirmation("unavailable status") { failed in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                },
                status: { status in
                    sink.receive(status: status)
                    if case .unavailable = status {
                        failed()
                    }
                }
            )
            let worker = Task { await queue.run(with: session) }
            defer { worker.cancel() }

            queue.enqueue(makeSentence(index: 0, text: sentenceText))
            await waitUntil(timeout: resultTimeout) {
                if case .unavailable = queue.status {
                    return true
                }
                return false
            }
        }

        #expect(sink.statuses.count == 3)
        #expect(Array(sink.statuses.prefix(2)) == [.ready, .translating])
        guard case let .unavailable(message) = queue.status else {
            Issue.record("expected .unavailable, got \(queue.status)")
            return
        }
        #expect(!message.isEmpty)

        let start = Date()
        let drained = await queue.drain(timeout: 1.0)
        #expect(!drained)
        #expect(
            Date().timeIntervalSince(start) < 0.8,
            "drain must early-return on .unavailable, not wait out the deadline"
        )
    }
}

/// Records handler callbacks so tests assert on real deliveries.
private final class QueueSink {
    private(set) var results: [(index: Int, translation: SentenceTranslation)] = []
    private(set) var statuses: [TranslationStatus] = []

    func receive(index: Int, translation: SentenceTranslation) {
        results.append((index, translation))
    }

    func receive(status: TranslationStatus) {
        statuses.append(status)
    }
}
