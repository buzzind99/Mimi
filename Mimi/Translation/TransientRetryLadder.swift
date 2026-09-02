import Foundation

/// Shared transient-failure retry ladder for cloud engines: 2 retries with
/// exponential backoff (0.5 s → 2 s), `Retry-After` respected when the
/// transport surfaced one (already capped at 10 s by the transport).
///
/// Non-transient errors (`invalidKey`, `quotaExceeded`, `badResponse`,
/// `cancelled`) and exhausted retries rethrow the original error untouched —
/// `CancellationError` in particular must reach `TranslationQueue` so a torn
/// down run lands on `.idle`, not `.unavailable`.
struct TransientRetryLadder: Sendable {
    let retries: Int
    let backoffs: [Duration]
    let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - retries: transient retries after the first attempt (default 2).
    ///   - backoffs: delay before retry *n* (0-based failure index).
    ///   - sleep: injectable for tests (no real waiting).
    init(
        retries: Int = 2,
        backoffs: [Duration] = [.milliseconds(500), .seconds(2)],
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.retries = retries
        self.backoffs = backoffs
        self.sleep = sleep
    }

    /// Runs `operation`, retrying transient failures. `onRetry` fires before
    /// each retry with `attemptsLeft` = retries remaining from that point.
    func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T,
        stage: RetryProgress.Stage = .batchRetry,
        onRetry: (@Sendable (RetryProgress) -> Void)? = nil
    ) async throws -> T {
        for attempt in 0 ... retries {
            do {
                return try await operation()
            } catch {
                guard attempt < retries, Self.isTransient(error) else { throw error }
                onRetry?(RetryProgress(stage: stage, attemptsLeft: retries - attempt))
                let delay = Self.retryAfter(of: error).map(Duration.seconds)
                    ?? backoffs[min(attempt, backoffs.count - 1)]
                try await sleep(delay)
            }
        }
        // Unreachable: the loop either returns or throws on every path.
        throw TranslationEngineError.network
    }

    static func isTransient(_ error: Error) -> Bool {
        switch engineError(of: error) {
        case .rateLimited, .network, .serverError: true
        default: false
        }
    }

    /// Normalizes any engine-surface error into the taxonomy (without
    /// consuming `CancellationError`, which passes through as `.cancelled`
    /// only for classification, never as a thrown replacement).
    static func engineError(of error: Error) -> TranslationEngineError {
        switch error {
        case let failure as HTTPTranslationTransport.Failure: failure.engineError
        case let engineError as TranslationEngineError: engineError
        case is CancellationError: .cancelled
        default: .network
        }
    }

    static func retryAfter(of error: Error) -> TimeInterval? {
        (error as? HTTPTranslationTransport.Failure)?.retryAfter
    }
}

/// Short user-facing copy for engine errors — used by the Settings Test
/// button now and mapped into `TranslationStatus`.
extension TranslationEngineError {
    var statusMessage: String {
        switch self {
        case .invalidKey: "Invalid API key"
        case .quotaExceeded: "API quota exceeded"
        case .rateLimited: "Rate limited by the provider"
        case let .serverError(code): "Provider server error (\(code))"
        case let .badResponse(detail): "Unexpected provider response: \(detail)"
        case .network: "Network error"
        case .cancelled: "Cancelled"
        }
    }
}
