import Foundation
@testable import Mimi
import Testing

/// Tests the shared transient-retry ladder: attempt counts, backoff
/// selection (including `Retry-After`), progress reporting, and the
/// non-transient fast path. Sleeps are injected no-ops.
@Suite("TransientRetryLadder")
struct TransientRetryLadderTests {

    /// Locked counters for `@Sendable` closures.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var delays: [Duration] = []
        private(set) var calls = 0
        private(set) var entries: [RetryProgress] = []

        func recordCall() {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
        }

        func recordDelay(_ duration: Duration) {
            lock.lock()
            defer { lock.unlock() }
            delays.append(duration)
        }

        func recordProgress(_ progress: RetryProgress) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(progress)
        }
    }

    private func makeLadder(log: Log) -> TransientRetryLadder {
        TransientRetryLadder(sleep: { duration in log.recordDelay(duration) })
    }

    @Test("transient failures retry twice with exponential backoff")
    func retriesTwiceThenSucceeds() async throws {
        let log = Log()
        let ladder = makeLadder(log: log)

        let result = try await ladder.run {
            log.recordCall()
            if log.calls < 3 {
                throw TranslationEngineError.rateLimited
            }
            return "ok"
        }

        #expect(result == "ok")
        #expect(log.calls == 3)
        #expect(log.delays == [.milliseconds(500), .seconds(2)])
    }

    @Test("exhausted retries rethrow the last error untouched")
    func exhaustionRethrows() async {
        let ladder = makeLadder(log: Log())

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await ladder.run { throw TranslationEngineError.network }
        }

        #expect(thrown == .network)
    }

    @Test("non-transient errors throw immediately without retries")
    func nonTransientFailsFast() async throws {
        let log = Log()
        let ladder = makeLadder(log: log)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await ladder.run {
                log.recordCall()
                throw TranslationEngineError.invalidKey
            }
        }

        #expect(thrown == .invalidKey)
        #expect(log.calls == 1)
        #expect(log.delays.isEmpty)
    }

    @Test("badResponse is non-transient by default")
    func badResponseNotRetriedByDefault() async throws {
        let log = Log()
        let ladder = makeLadder(log: log)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await ladder.run {
                log.recordCall()
                throw TranslationEngineError.badResponse("rambled")
            }
        }

        #expect(thrown == .badResponse("rambled"))
        #expect(log.calls == 1)
        #expect(log.delays.isEmpty)
    }

    @Test("badResponse retries when the ladder opts in")
    func badResponseRetriedWhenOptedIn() async throws {
        let log = Log()
        let ladder = TransientRetryLadder(
            retriesBadResponse: true,
            sleep: { log.recordDelay($0) }
        )

        let result = try await ladder.run {
            log.recordCall()
            if log.calls < 3 {
                throw TranslationEngineError.badResponse("rambled")
            }
            return "ok"
        }

        #expect(result == "ok")
        #expect(log.calls == 3)
        #expect(log.delays == [.milliseconds(500), .seconds(2)])
    }

    @Test("an opted-in ladder still fails invalidKey immediately")
    func optedInLadderKeepsInvalidKeyNonTransient() async throws {
        let log = Log()
        let ladder = TransientRetryLadder(
            retriesBadResponse: true,
            sleep: { log.recordDelay($0) }
        )

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await ladder.run {
                log.recordCall()
                throw TranslationEngineError.invalidKey
            }
        }

        #expect(thrown == .invalidKey)
        #expect(log.calls == 1)
        #expect(log.delays.isEmpty)
    }

    @Test("a transport Retry-After overrides the default backoff")
    func retryAfterRespected() async throws {
        let log = Log()
        let ladder = makeLadder(log: log)

        _ = try await ladder.run {
            log.recordCall()
            if log.calls == 1 {
                throw HTTPTranslationTransport.Failure(engineError: .rateLimited, retryAfter: 3)
            }
            return "ok"
        }

        #expect(log.delays == [.seconds(3)])
    }

    @Test("onRetry reports the stage and remaining attempts")
    func progressReporting() async throws {
        let log = Log()
        let ladder = makeLadder(log: log)

        _ = try await ladder.run {
            log.recordCall()
            if log.calls < 3 {
                throw TranslationEngineError.serverError(500)
            }
            return "ok"
        } onRetry: {
            log.recordProgress($0)
        }

        #expect(log.entries == [
            RetryProgress(stage: .batchRetry, attemptsLeft: 2),
            RetryProgress(stage: .batchRetry, attemptsLeft: 1)
        ])
    }

    @Test("cancellation propagates as CancellationError")
    func cancellationPropagates() async {
        let ladder = makeLadder(log: Log())

        await #expect(throws: CancellationError.self) {
            try await ladder.run { throw CancellationError() }
        }
    }

    // MARK: - Status copy

    @Test("status copy renders every engine error")
    func statusMessageRendersEveryError() {
        #expect(TranslationEngineError.invalidKey.statusMessage == "Invalid API key")
        #expect(TranslationEngineError.quotaExceeded.statusMessage == "API quota exceeded")
        #expect(TranslationEngineError.rateLimited.statusMessage == "Rate limited by the provider")
        #expect(TranslationEngineError.serverError(503).statusMessage == "Provider server error (503)")
        #expect(
            TranslationEngineError.badResponse("boom").statusMessage
                == "Unexpected provider response: boom"
        )
        #expect(TranslationEngineError.network.statusMessage == "Network error")
        #expect(TranslationEngineError.cancelled.statusMessage == "Cancelled")
    }
}
