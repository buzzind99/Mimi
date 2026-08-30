@testable import Mimi
@preconcurrency import Translation
import XCTest

/// Tests `TranslationQueue` handler wiring, cache-hit enqueue, retry reset, and
/// drain bounds. The delivery paths run against the real OS ja→en pack via
/// `TranslationSession(installedSource:)` (macOS 26+; skipped when the pack is
/// missing) so the enqueue cache can be seeded through the handler loop.
@MainActor
final class TranslationQueueTests: XCTestCase {

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

    /// Real session for the installed ja→en pair. `translate` runs locally once
    /// the pack is present (no prompts); skipped otherwise so the suite stays
    /// green on machines without the pack.
    private func makeInstalledJAToENSession() async throws -> TranslationSession {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("TranslationSession(installedSource:) requires macOS 26")
        }
        let source = Locale.Language(identifier: "ja")
        let target = Locale.Language(identifier: "en")
        let availability = LanguageAvailability()
        guard await availability.status(from: source, to: target) == .installed else {
            throw XCTSkip("ja→en translation pack is not installed")
        }
        return TranslationSession(installedSource: source, target: target)
    }

    /// Session whose `translate` deterministically throws: target "zz" is
    /// unsupported, so the worker always lands in its error path. The
    /// non-throwing `init(installedSource:)` requires the source pack to exist,
    /// so the installed ja→en pair gates it as a proxy for "ja pack present".
    private func makeUnsupportedTargetSession() async throws -> TranslationSession {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("TranslationSession(installedSource:) requires macOS 26")
        }
        let source = Locale.Language(identifier: "ja")
        let availability = LanguageAvailability()
        guard await availability.status(
            from: source, to: Locale.Language(identifier: "en")
        ) == .installed else {
            throw XCTSkip("ja translation pack is not installed")
        }
        return TranslationSession(installedSource: source, target: Locale.Language(identifier: "zz"))
    }

    // MARK: - setHandlers

    func test_setHandlers_whenStatusChanges_shouldInvokeStatusHandler() {
        let (queue, sink) = makeSUT()
        // Result-handler wiring is exercised by the cache-hit tests below.
        queue.setHandlers(
            result: { _, _ in },
            status: { sink.receive(status: $0) }
        )

        queue.resetForRetry()

        XCTAssertEqual(sink.statuses, [.idle])
    }

    // MARK: - resetForRetry

    func test_resetForRetry_whenIdle_shouldClearStatusToIdle() {
        let (queue, sink) = makeSUT()
        queue.setHandlers(
            result: { _, _ in },
            status: { sink.receive(status: $0) }
        )

        queue.resetForRetry()

        XCTAssertEqual(queue.status, .idle)
        XCTAssertEqual(sink.statuses, [.idle])
    }

    // MARK: - drain

    func test_drain_whenNothingPending_shouldReturnTrue() async {
        let queue = TranslationQueue()

        let drained = await queue.drain(timeout: 0.05)

        XCTAssertTrue(drained)
    }

    /// A sentence enqueued with no worker attached (no `run(with:)` yet) sits
    /// in `pending`, so a bounded drain must time out instead of completing.
    func test_drain_whenPendingWithoutWorker_shouldTimeOut() async {
        let queue = TranslationQueue()
        queue.enqueue(makeSentence(index: 0, text: sentenceText))

        let drained = await queue.drain(timeout: 0.05)

        XCTAssertFalse(drained)
    }

    // MARK: - run(with:) single delivery + resetForRetry from non-idle

    func test_run_whenSingleSentenceEnqueued_shouldDeliverThroughStatusCycle() async throws {
        let session = try await makeInstalledJAToENSession()
        let (queue, sink) = makeSUT()
        let delivered = expectation(description: "translation delivered")
        queue.setHandlers(
            result: { index, translation in
                sink.receive(index: index, translation: translation)
                delivered.fulfill()
            },
            status: { sink.receive(status: $0) }
        )
        let worker = Task { await queue.run(with: session) }
        defer { worker.cancel() }

        queue.enqueue(makeSentence(index: 0, text: sentenceText))
        await fulfillment(of: [delivered], timeout: resultTimeout)

        XCTAssertEqual(sink.results.count, 1)
        XCTAssertEqual(sink.results[0].index, 0)
        XCTAssertEqual(sink.results[0].translation.lang, "en")
        XCTAssertFalse(sink.results[0].translation.text.isEmpty)
        XCTAssertEqual(sink.statuses, [.ready, .translating, .ready])

        // Retry reset also clears a non-idle (.ready) status.
        queue.resetForRetry()
        XCTAssertEqual(queue.status, .idle)
        XCTAssertEqual(sink.statuses, [.ready, .translating, .ready, .idle])
    }

    // MARK: - run(with:) wake loop

    /// Enqueues while the worker is already parked in the wake loop — the
    /// incremental path that keeps one session alive for follow-up sentences.
    func test_run_whenEnqueuedWhileWorkerIdle_shouldWakeAndDeliver() async throws {
        let session = try await makeInstalledJAToENSession()
        let (queue, sink) = makeSUT()
        let first = expectation(description: "first translation delivered")
        let second = expectation(description: "second translation delivered")
        queue.setHandlers(
            result: { index, translation in
                sink.receive(index: index, translation: translation)
                if index == 0 {
                    first.fulfill()
                } else {
                    second.fulfill()
                }
            },
            status: { sink.receive(status: $0) }
        )
        let worker = Task { await queue.run(with: session) }
        defer { worker.cancel() }

        queue.enqueue(makeSentence(index: 0, text: sentenceText))
        await fulfillment(of: [first], timeout: resultTimeout)
        // Wait for the worker to publish .ready again (batch done), so the
        // second enqueue lands on an idle worker and must wake it.
        for _ in 0 ..< 500 where queue.status != .ready {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(queue.status, .ready)

        queue.enqueue(makeSentence(index: 1, text: otherSentenceText))
        await fulfillment(of: [second], timeout: resultTimeout)

        XCTAssertEqual(sink.results.count, 2)
        XCTAssertEqual(sink.results[1].index, 1)
        XCTAssertEqual(sink.results[1].translation.lang, "en")
        XCTAssertFalse(sink.results[1].translation.text.isEmpty)
        XCTAssertEqual(sink.statuses, [.ready, .translating, .ready, .translating, .ready])
    }

    // MARK: - enqueue cache hit

    /// Seeds the cache through the worker's delivery path, then re-enqueues the
    /// same text under a new index: the cached result must post synchronously
    /// at enqueue time and never enter `pending`.
    func test_enqueue_whenCacheHit_shouldPostSynchronouslyAndBypassPending() async throws {
        let session = try await makeInstalledJAToENSession()
        let (queue, sink) = makeSUT()
        let seeded = expectation(description: "seed result delivered")
        seeded.assertForOverFulfill = false
        queue.setHandlers(
            result: { index, translation in
                sink.receive(index: index, translation: translation)
                seeded.fulfill()
            },
            status: { sink.receive(status: $0) }
        )
        let worker = Task { await queue.run(with: session) }
        defer { worker.cancel() }

        queue.enqueue(makeSentence(index: 0, text: sentenceText))
        await fulfillment(of: [seeded], timeout: resultTimeout)
        let seed = sink.results[0].translation

        queue.enqueue(makeSentence(index: 5, text: sentenceText))

        XCTAssertEqual(sink.results.count, 2, "cache hit must post without awaiting")
        XCTAssertEqual(sink.results[1].index, 5)
        XCTAssertEqual(sink.results[1].translation, seed)
        let drained = await queue.drain(timeout: 0.05)
        XCTAssertTrue(drained, "cache hit must bypass pending")
    }

    // MARK: - run(with:) cancellation

    /// Cancelling the worker before its body runs makes `session.translate`
    /// throw `CancellationError` deterministically: the sentence must be
    /// re-queued for the next run and the status returned to `.idle`.
    func test_run_whenCancelledBeforeStart_shouldRequeueAndReturnToIdle() async throws {
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

        XCTAssertTrue(sink.results.isEmpty)
        XCTAssertEqual(sink.statuses, [.ready, .translating, .idle])
        let drained = await queue.drain(timeout: 0.05)
        XCTAssertFalse(drained, "cancelled work must be re-queued, not lost")
    }

    // MARK: - run(with:) batch delivery

    /// Both enqueues happen before the (main-actor) worker resumes, so the
    /// worker must translate them as one batched round-trip: one
    /// translating→ready cycle for two results, FIFO order preserved.
    func test_run_whenBurstEnqueued_shouldDeliverAsSingleBatchInOrder() async throws {
        let session = try await makeInstalledJAToENSession()
        let (queue, sink) = makeSUT()
        let delivered = expectation(description: "batch delivered")
        delivered.expectedFulfillmentCount = 2
        queue.setHandlers(
            result: { index, translation in
                sink.receive(index: index, translation: translation)
                delivered.fulfill()
            },
            status: { sink.receive(status: $0) }
        )
        let worker = Task { await queue.run(with: session) }
        defer { worker.cancel() }

        queue.enqueue(makeSentence(index: 0, text: sentenceText))
        queue.enqueue(makeSentence(index: 1, text: otherSentenceText))
        await fulfillment(of: [delivered], timeout: resultTimeout)

        XCTAssertEqual(sink.results.map { $0.index }, [0, 1])
        XCTAssertEqual(sink.statuses, [.ready, .translating, .ready], "one batched round-trip")
    }

    // MARK: - run(with:) failure path

    /// An unsupported target makes `translate` throw deterministically; the
    /// worker must re-queue the sentence, publish `.unavailable`, and exit —
    /// after which `drain` fails fast instead of waiting out its timeout.
    func test_run_whenTranslationFails_shouldPublishUnavailableAndFailDrainFast() async throws {
        let session = try await makeUnsupportedTargetSession()
        let (queue, sink) = makeSUT()
        let failed = expectation(description: "unavailable status")
        queue.setHandlers(
            result: { index, translation in
                sink.receive(index: index, translation: translation)
            },
            status: { status in
                sink.receive(status: status)
                if case .unavailable = status {
                    failed.fulfill()
                }
            }
        )
        let worker = Task { await queue.run(with: session) }
        defer { worker.cancel() }

        queue.enqueue(makeSentence(index: 0, text: sentenceText))
        await fulfillment(of: [failed], timeout: resultTimeout)

        XCTAssertEqual(sink.statuses.count, 3)
        XCTAssertEqual(Array(sink.statuses.prefix(2)), [.ready, .translating])
        guard case let .unavailable(message) = queue.status else {
            return XCTFail("expected .unavailable, got \(queue.status)")
        }
        XCTAssertFalse(message.isEmpty)

        let start = Date()
        let drained = await queue.drain(timeout: 1.0)
        XCTAssertFalse(drained)
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 0.8,
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
