import Foundation

/// Progress report fired by an engine while it retries a failed request.
/// Drives the footer copy ("External translation failed, N retries left").
struct RetryProgress: Equatable, Sendable {
    /// Where in the failure ladder the retry sits.
    enum Stage: Equatable, Sendable {
        /// The whole batch is being retried after a transient failure.
        case batchRetry
        /// The batch failed permanently; individual sentences are being
        /// retried one request each (OpenRouter only).
        case perSentenceSplit
    }

    let stage: Stage
    /// Attempts remaining before the engine gives up.
    let attemptsLeft: Int
}

/// Engine error taxonomy — one language for every provider. Transport layers
/// map HTTP failures onto these cases; the queue and `AppModel` map them onto
/// user-facing status copy.
enum TranslationEngineError: Error, Equatable, Sendable {
    case invalidKey
    case quotaExceeded
    case rateLimited
    case serverError(Int)
    case badResponse(String)
    case network
    case cancelled
}

/// A batch translation engine behind `TranslationQueue` — the seam that lets
/// Apple on-device, Google, DeepL, and OpenRouter slot in behind one worker
/// loop. Conformers must be safe to call from any task; the queue serializes
/// calls, so engines never see concurrent `translate` invocations.
protocol TranslationEngine: Sendable {
    /// Upper bound on how many sentences the queue batches into one
    /// `translate` call (long batches degrade small LLMs; cloud APIs cap
    /// request size).
    var preferredBatchSize: Int { get }

    /// Optional retry-progress hook, wired to the UI by the engine owner.
    /// Never fired on-device; cloud engines fire it per retry attempt.
    var onRetry: (@Sendable (RetryProgress) -> Void)? { get set }

    /// Translates the given texts 1:1, preserving order. Throws
    /// `TranslationEngineError` on failure, or `CancellationError` when the
    /// calling task is cancelled.
    func translate(_ texts: [String]) async throws -> [String]
}
