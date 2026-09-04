import Foundation
@testable import Mimi
import Testing

/// Queue-level tests for the failure ladder: fallback re-entry
/// (a second `run(with:)` after a dead one) preserves `pending` + cache, the
/// generation token retires a dead run without clobbering the live one,
/// cancellation mid-batch re-queues, and `noteRetry` surfaces retry progress
/// without clobbering terminal or post-batch states.
///
/// Swift Testing confirmations have no timeout, so every wait inside a
/// confirmation scope is bounded by `pollUntil(timeout:)`.
@MainActor
@Suite("TranslationQueue fallback ladder")
struct TranslationQueueFallbackTests {

    // MARK: - Fixtures

    private let sentenceText = "テスト"
    private let otherSentenceText = "こんにちは"

    private func makeSentence(index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
    }

    /// Deterministic prefixing mock that records each batch (mirrors the
    /// private mock in `TranslationQueueTests`).
    private final class EchoEngine: TranslationEngine, @unchecked Sendable {
        let preferredBatchSize = 16
        var onRetry: (@Sendable (RetryProgress) -> Void)?

        private let lock = NSLock()
        private var batches: [[String]] = []
        private let transform: @Sendable (String) async throws -> String

        init(transform: @escaping @Sendable (String) async throws -> String = { "EN:\($0)" }) {
            self.transform = transform
        }

        var recordedBatches: [[String]] {
            lock.withLock { batches }
        }

        func translate(_ texts: [String]) async throws -> [String] {
            lock.withLock { batches.append(texts) }
            var output: [String] = []
            for text in texts {
                try output.append(await transform(text))
            }
            return output
        }
    }

    /// Fires one retry-progress report mid-call (the in-engine ladder
    /// simulation) and then succeeds, so the queue renders
    /// translating → retrying → ready.
    private final class RetryThenSucceedEngine: TranslationEngine, @unchecked Sendable {
        let preferredBatchSize = 16
        var onRetry: (@Sendable (RetryProgress) -> Void)?
        private var fired = false

        func translate(_ texts: [String]) async throws -> [String] {
            if !fired {
                fired = true
                onRetry?(RetryProgress(stage: .batchRetry, attemptsLeft: 2))
                // Yield so the main-actor `noteRetry` hop lands before return.
                try? await Task.sleep(for: .milliseconds(50))
            }
            return texts.map { "EN:\($0)" }
        }
    }

    /// Records statuses; results land in a plain array.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var statusLog: [TranslationStatus] = []
        private var resultLog: [Int] = []

        func record(status: TranslationStatus) {
            lock.withLock { statusLog.append(status) }
        }

        func record(result index: Int) {
            lock.withLock { resultLog.append(index) }
        }

        var statuses: [TranslationStatus] {
            lock.withLock { statusLog }
        }

        var results: [Int] {
            lock.withLock { resultLog }
        }
    }

    // MARK: - Fallback re-entry preserves pending + cache

    /// The fallback flow at the queue level: a dead external run exits
    /// with `.unavailable` and its batch back in `pending`; the replacement
    /// (Apple) run replays it 1:1; the cache seeded by the replacement run
    /// serves repeats without touching the engine again.
    @Test("fallback re-entry replays pending and seeds the cache")
    func fallbackReentryReplaysPendingAndSeedsCache() async {
        let dead = EchoEngine(transform: { _ in throw RuntimeError("dead engine") })
        let replacement = EchoEngine()
        let queue = TranslationQueue()
        let sink = Sink()
        queue.setHandlers(
            result: { index, _ in sink.record(result: index) },
            status: { sink.record(status: $0) }
        )

        queue.enqueue(makeSentence(index: 0, text: sentenceText))
        queue.enqueue(makeSentence(index: 1, text: otherSentenceText))

        _ = Task { await queue.run(with: dead) }
        await pollUntil(timeout: 5) {
            if case .unavailable = queue.status {
                return true
            }
            return false
        }
        #expect(sink.results.isEmpty, "the dead run must not deliver")

        let replacementWorker = Task { await queue.run(with: replacement) }
        await pollUntil(timeout: 5) { sink.results.count == 2 }

        #expect(sink.results == [0, 1], "the surviving pending must replay in order")
        #expect(queue.status == .ready)
        #expect(replacement.recordedBatches.count == 1, "a burst replays as one batch")

        // Cache seeded by the replacement run: a repeat posts synchronously
        // and never reaches the engine again.
        queue.enqueue(makeSentence(index: 5, text: sentenceText))
        #expect(sink.results == [0, 1, 5])
        #expect(replacement.recordedBatches.count == 1)

        replacementWorker.cancel()
    }

    // MARK: - Cancellation mid-batch requeues

    /// Cancelling the worker while a batch is in flight must re-queue the
    /// batch (status `.idle`, not an error) so a later run replays it.
    @Test("an engine cancelled mid-batch requeues its batch")
    func cancelledMidBatchRequeues() async {
        let queue = TranslationQueue()
        let sink = Sink()
        queue.setHandlers(
            result: { index, _ in sink.record(result: index) },
            status: { sink.record(status: $0) }
        )

        queue.enqueue(makeSentence(index: 0, text: sentenceText))

        // Sleeps only long enough to be observably in-flight: cancellation
        // must interrupt it, so a lost propagation fails in ~2 s instead of
        // stalling the suite.
        let sleeper = EchoEngine { _ in
            try await Task.sleep(for: .seconds(2))
            return "unreachable"
        }
        let worker = Task { await queue.run(with: sleeper) }
        await pollUntil(timeout: 5) { queue.status == .translating }

        worker.cancel()
        await worker.value

        #expect(queue.status == .idle)
        #expect(sink.results.isEmpty)
        let drained = await queue.drain(timeout: 0.05)
        #expect(!drained, "the cancelled batch must be re-queued, not lost")

        // The replay: a fresh run translates the surviving batch.
        let replacement = EchoEngine()
        let replacementWorker = Task { await queue.run(with: replacement) }
        await pollUntil(timeout: 5) { sink.results.count == 1 }
        #expect(sink.results == [0])

        replacementWorker.cancel()
    }

    // MARK: - noteRetry

    /// An external engine's retry report surfaces as `.retrying` between
    /// `.translating` and the next outcome, with the footer copy.
    @Test("noteRetry renders translating → retrying → ready with footer copy")
    func noteRetrySurfacesBetweenTranslatingAndReady() async {
        let queue = TranslationQueue()
        let sink = Sink()
        queue.setHandlers(
            result: { index, _ in sink.record(result: index) },
            status: { sink.record(status: $0) }
        )
        let engine = RetryThenSucceedEngine()
        engine.onRetry = { progress in
            Task { @MainActor in queue.noteRetry(progress) }
        }

        queue.enqueue(makeSentence(index: 0, text: sentenceText))
        let worker = Task { await queue.run(with: engine) }
        await pollUntil(timeout: 5) { sink.results.count == 1 }
        worker.cancel()

        #expect(sink.results == [0])
        #expect(sink.statuses == [.ready, .translating, .retrying("External translation failed, 2 retries left"), .ready])
    }

    /// A late retry report (the main-actor hop landing after the batch
    /// failed out) must not clobber `.unavailable`.
    @Test("a stale noteRetry cannot clobber .unavailable")
    func staleNoteRetryCannotClobberUnavailable() async {
        let queue = TranslationQueue()
        queue.setHandlers(result: { _, _ in }, status: { _ in })
        let engine = EchoEngine(transform: { _ in throw RuntimeError("dead") })

        queue.enqueue(makeSentence(index: 0, text: sentenceText))
        let worker = Task { await queue.run(with: engine) }
        await pollUntil(timeout: 5) {
            if case .unavailable = queue.status {
                return true
            }
            return false
        }
        worker.cancel()

        queue.noteRetry(RetryProgress(stage: .batchRetry, attemptsLeft: 1))

        guard case .unavailable = queue.status else {
            Issue.record("expected .unavailable to survive, got \(queue.status)")
            return
        }
    }

    /// A late retry report landing after the batch already succeeded (the
    /// main-actor hop losing the race to the result) must not clobber
    /// `.ready` with "N retries left" — the batch outcome is the truth.
    @Test("a stale noteRetry cannot clobber .ready")
    func staleNoteRetryCannotClobberReady() async {
        let queue = TranslationQueue()
        let sink = Sink()
        queue.setHandlers(
            result: { index, _ in sink.record(result: index) },
            status: { sink.record(status: $0) }
        )
        let engine = EchoEngine()

        queue.enqueue(makeSentence(index: 0, text: sentenceText))
        let worker = Task { await queue.run(with: engine) }
        await pollUntil(timeout: 5) { sink.results.count == 1 }
        #expect(queue.status == .ready)
        worker.cancel()

        queue.noteRetry(RetryProgress(stage: .batchRetry, attemptsLeft: 1))

        #expect(queue.status == .ready, "expected .ready to survive, got \(queue.status)")
    }
}

/// Small error for mock engines.
private struct RuntimeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
