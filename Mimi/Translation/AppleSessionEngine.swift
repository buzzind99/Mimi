import Foundation
import Translation

/// `TranslationEngine` adapter around the on-device `TranslationSession`
/// SwiftUI hands out via `.translationTask`. Batches through
/// `translations(from:)`, which amortizes the model round-trip across the
/// batch exactly as the queue has always batched on-device work.
struct AppleSessionEngine: TranslationEngine {
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
