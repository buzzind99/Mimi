import Foundation
import Translation

/// `TranslationEngine` adapter around the on-device `TranslationSession`
/// SwiftUI hands out via `.translationTask`. Batches through
/// `translations(from:)`, which amortizes the model round-trip across the
/// batch exactly as the queue has always batched on-device work.
///
/// `@unchecked Sendable`: the `Translation` framework does not mark
/// `TranslationSession` Sendable, but the session handed out by
/// `.translationTask` is used only through this engine's `translate` calls
/// (session methods are nonisolated and self-synchronizing in practice).
struct AppleSessionEngine: TranslationEngine, @unchecked Sendable {
    let preferredBatchSize = 16

    /// On-device translation never retries — the hook stays unset.
    var onRetry: (@Sendable (RetryProgress) -> Void)?

    private let session: TranslationSession

    init(_ session: TranslationSession) {
        self.session = session
    }

    func translate(_ texts: [String]) async throws -> [String] {
        let requests = texts.map { TranslationSession.Request(sourceText: $0) }
        let responses = try await session.translations(from: requests)
        return responses.map { $0.targetText }
    }
}
