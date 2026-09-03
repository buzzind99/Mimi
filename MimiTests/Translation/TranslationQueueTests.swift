import Foundation
@testable import Mimi
import Testing
@preconcurrency import Translation

/// Tests `TranslationQueue` handler wiring, cache-hit enqueue, retry reset,
/// drain bounds, and the worker loop against a hermetic closure-backed mock
/// engine (no macOS-26 / pack gating). One smoke test runs the real OS ja→en
/// pack through `AppleSessionEngine` to keep the adapter honest.
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
    private let resultTimeout: TimeInterval = 5

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

    /// Deterministic mock: prefixes every input, recording each batch. Lock
    /// guards the recording because `translate` runs off the main actor.
    private func makeEchoEngine(batchSize: Int = 16) -> MockTranslationEngine {
        MockTranslationEngine(preferredBatchSize: batchSize) { texts in
            texts.map { "EN:\($0)" }
        }
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
        let engine = makeEchoEngine()
        let (queue, sink) = makeSUT()
        await confirmation("translation delivered") { delivered in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                    delivered()
                },
                status: { sink.receive(status: $0) }
            )
            let worker = Task { await queue.run(with: engine) }
            defer { worker.cancel() }

            queue.enqueue(makeSentence(index: 0, text: sentenceText))
            await waitUntil(timeout: resultTimeout) { sink.results.count == 1 }
        }

        let delivery = try #require(sink.results.first)
        #expect(sink.results.count == 1)
        #expect(delivery.index == 0)
        #expect(delivery.translation.lang == "en")
        #expect(delivery.translation.text == "EN:\(sentenceText)")
        #expect(sink.statuses == [.ready, .translating, .ready])

        // Retry reset also clears a non-idle (.ready) status.
        queue.resetForRetry()
        #expect(queue.status == .idle)
        #expect(sink.statuses == [.ready, .translating, .ready, .idle])
    }

    // MARK: - run(with:) wake loop

    /// Enqueues while the worker is already parked in the wake loop — the
    /// incremental path that keeps one engine alive for follow-up sentences.
    @Test("an enqueue on an idle worker wakes the loop and delivers")
    func enqueueOnIdleWorkerWakesAndDelivers() async throws {
        let engine = makeEchoEngine()
        let (queue, sink) = makeSUT()
        await confirmation("both translations delivered", expectedCount: 2) { delivered in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                    delivered()
                },
                status: { sink.receive(status: $0) }
            )
            let worker = Task { await queue.run(with: engine) }
            defer { worker.cancel() }

            queue.enqueue(makeSentence(index: 0, text: sentenceText))
            await waitUntil(timeout: resultTimeout) { sink.results.count == 1 }
            // Wait for the worker to publish .ready again (batch done), so the
            // second enqueue lands on an idle worker and must wake it.
            await waitUntil(timeout: resultTimeout) { queue.status == .ready }
            #expect(queue.status == .ready)

            queue.enqueue(makeSentence(index: 1, text: otherSentenceText))
            await waitUntil(timeout: resultTimeout) { sink.results.count == 2 }
        }

        let second = try #require(sink.results.last)
        #expect(sink.results.count == 2)
        #expect(second.index == 1)
        #expect(second.translation.lang == "en")
        #expect(second.translation.text == "EN:\(otherSentenceText)")
        #expect(sink.statuses == [.ready, .translating, .ready, .translating, .ready])
    }

    // MARK: - enqueue cache hit

    /// Seeds the cache through the worker's delivery path, then re-enqueues the
    /// same text under a new index: the cached result must post synchronously
    /// at enqueue time and never enter `pending`.
    @Test("a repeat enqueue posts the cached result synchronously, bypassing pending")
    func cacheHitPostsSynchronouslyAndBypassesPending() async throws {
        let engine = makeEchoEngine()
        let (queue, sink) = makeSUT()
        try await confirmation("results delivered", expectedCount: 1...) { delivered in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                    delivered()
                },
                status: { sink.receive(status: $0) }
            )
            let worker = Task { await queue.run(with: engine) }
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
        #expect(engine.recordedBatches.count == 1, "cache hit must bypass the engine")
    }

    // MARK: - enqueue skip-empty

    /// Empty and whitespace-only finals never reach the engine: they are
    /// dropped at `enqueue` and drain succeeds immediately (nothing pending).
    @Test("empty and whitespace-only sentences never reach the engine", arguments: ["", " ", "\t\n　 "])
    func emptyAndWhitespaceSentencesNeverReachTheEngine(text: String) async {
        let engine = makeEchoEngine()
        let (queue, sink) = makeSUT()
        queue.setHandlers(
            result: { index, translation in
                sink.receive(index: index, translation: translation)
            },
            status: { sink.receive(status: $0) }
        )

        queue.enqueue(makeSentence(index: 0, text: text))

        #expect(sink.results.isEmpty, "an empty sentence must not deliver a translation")
        let worker = Task { await queue.run(with: engine) }
        defer { worker.cancel() }
        let drained = await queue.drain(timeout: 0.05)
        #expect(drained, "an empty sentence must never enter pending")
        #expect(engine.recordedBatches.isEmpty)
    }

    /// A real sentence enqueued alongside empty ones still translates with
    /// its original index — skipping must not disturb FIFO order or indexing.
    @Test("real sentences around empty ones keep their order and indexes")
    func realSentencesAroundEmptyOnesKeepOrderAndIndexes() async {
        let engine = makeEchoEngine()
        let (queue, sink) = makeSUT()
        await confirmation("translation delivered", expectedCount: 2) { delivered in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                    delivered()
                },
                status: { sink.receive(status: $0) }
            )
            let worker = Task { await queue.run(with: engine) }
            defer { worker.cancel() }

            queue.enqueue(makeSentence(index: 0, text: sentenceText))
            queue.enqueue(makeSentence(index: 1, text: "   "))
            queue.enqueue(makeSentence(index: 2, text: otherSentenceText))
            await waitUntil(timeout: resultTimeout) { sink.results.count == 2 }
        }

        #expect(sink.results.map { $0.index } == [0, 2])
        #expect(engine.recordedBatches.map { $0.count } == [2], "empties never split the batch")
    }

    // MARK: - run(with:) batch sizing

    /// The engine's `preferredBatchSize` bounds each round-trip: three
    /// sentences against a size-2 engine must arrive as one batch of two
    /// followed by a batch of one, FIFO order preserved.
    @Test("the engine's preferredBatchSize bounds each round-trip")
    func preferredBatchSizeBoundsRoundTrips() async {
        let engine = makeEchoEngine(batchSize: 2)
        let (queue, sink) = makeSUT()
        await confirmation("batch delivered", expectedCount: 3) { delivered in
            queue.setHandlers(
                result: { index, translation in
                    sink.receive(index: index, translation: translation)
                    delivered()
                },
                status: { sink.receive(status: $0) }
            )
            let worker = Task { await queue.run(with: engine) }
            defer { worker.cancel() }

            for index in 0 ..< 3 {
                queue.enqueue(makeSentence(index: index, text: "\(sentenceText)\(index)"))
            }
            await waitUntil(timeout: resultTimeout) { sink.results.count == 3 }
        }

        #expect(engine.recordedBatches.map { $0.count } == [2, 1])
        #expect(sink.results.map { $0.index } == [0, 1, 2], "FIFO order preserved across batches")
    }

    // MARK: - run(with:) cancellation

    /// A `CancellationError` from the engine (task torn down / configuration
    /// invalidated) must re-queue the sentence for the next run and return
    /// the status to `.idle` — not surface as an error.
    @Test("a CancellationError re-queues the sentence and returns to idle")
    func cancellationErrorRequeuesAndReturnsToIdle() async {
        let engine = MockTranslationEngine { _ in throw CancellationError() }
        let (queue, sink) = makeSUT()
        queue.setHandlers(
            result: { index, translation in
                sink.receive(index: index, translation: translation)
            },
            status: { sink.receive(status: $0) }
        )

        queue.enqueue(makeSentence(index: 0, text: sentenceText))

        let worker = Task { await queue.run(with: engine) }
        await worker.value

        #expect(sink.results.isEmpty)
        #expect(sink.statuses == [.ready, .translating, .idle])
        let drained = await queue.drain(timeout: 0.05)
        #expect(!drained, "cancelled work must be re-queued, not lost")
    }

    // MARK: - run(with:) failure path

    /// An engine failure must re-queue the sentence, publish `.unavailable`,
    /// and exit — after which `drain` fails fast instead of waiting out its
    /// timeout.
    @Test("an engine failure publishes .unavailable and makes drain fail fast")
    func engineFailurePublishesUnavailableAndFailsDrainFast() async {
        let engine = MockTranslationEngine { _ in
            throw TranslationEngineError.badResponse("unparseable payload")
        }
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
            let worker = Task { await queue.run(with: engine) }
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

    // MARK: - AppleSessionEngine smoke (real pack)

    /// Keeps `AppleSessionEngine` exercised against the real OS ja→en pack:
    /// a single sentence in, a non-empty English translation out. Cancelled
    /// on machines without macOS 26 / the pack so the suite stays green.
    @Test("AppleSessionEngine delivers a real on-device translation")
    func appleSessionEngineDeliversRealTranslation() async throws {
        guard #available(macOS 26.0, *) else {
            try Test.cancel("TranslationSession(installedSource:) requires macOS 26")
        }
        guard await TestEnvironment.jaToENPackInstalled() else {
            try Test.cancel("ja→en translation pack is not installed")
        }
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: "en")
        )
        let engine = AppleSessionEngine(session)

        let translations = try await engine.translate([sentenceText])

        #expect(translations.count == 1)
        #expect(!translations[0].isEmpty)
    }
}

/// Closure-backed `TranslationEngine` so queue tests stay hermetic. Lock
/// guards the batch recording because `translate` runs off the main actor.
private final class MockTranslationEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize: Int
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let handler: @Sendable ([String]) async throws -> [String]
    private let lock = NSLock()
    private var batches: [[String]] = []

    init(
        preferredBatchSize: Int = 16,
        handler: @escaping @Sendable ([String]) async throws -> [String]
    ) {
        self.preferredBatchSize = preferredBatchSize
        self.handler = handler
    }

    var recordedBatches: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return batches
    }

    func translate(_ texts: [String]) async throws -> [String] {
        lock.lock()
        batches.append(texts)
        lock.unlock()
        return try await handler(texts)
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
