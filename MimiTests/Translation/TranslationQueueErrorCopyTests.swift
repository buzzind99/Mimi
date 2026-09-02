import Foundation
@testable import Mimi
import Testing
@preconcurrency import Translation

/// Locks the `.unavailable` status copy `TranslationQueue` renders: the
/// provider-specific copy for every engine-error taxonomy case, the
/// Translation-framework path, and the unknown-error fallback. Split from
/// `TranslationQueueTests` to keep both type bodies small.
@MainActor
@Suite("TranslationQueue error copy")
struct TranslationQueueErrorCopyTests {

    // MARK: - Helpers

    private let resultTimeout: TimeInterval = 5

    /// Engine that throws the scripted error on every call.
    private final class ThrowingEngine: TranslationEngine, @unchecked Sendable {
        let preferredBatchSize = 16
        var onRetry: (@Sendable (RetryProgress) -> Void)?

        private let handler: @Sendable () throws -> [String]

        init(handler: @escaping @Sendable () throws -> [String]) {
            self.handler = handler
        }

        func translate(_ texts: [String]) async throws -> [String] {
            try handler()
        }
    }

    /// Runs the queue against a throwing engine and returns the rendered
    /// `.unavailable` message.
    private func unavailableMessage(engine: TranslationEngine) async -> String? {
        let queue = TranslationQueue()
        queue.setHandlers(result: { _, _ in }, status: { _ in })
        queue.enqueue(Sentence(index: 0, startS: 0, endS: 1, lang: "ja", text: "テスト"))
        let worker = Task { await queue.run(with: engine) }
        let deadline = Date().addingTimeInterval(resultTimeout)
        while !isUnavailable(queue.status), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        worker.cancel()

        guard case let .unavailable(message) = queue.status else {
            Issue.record("expected .unavailable, got \(queue.status)")
            return nil
        }
        return message
    }

    private func isUnavailable(_ status: TranslationStatus) -> Bool {
        if case .unavailable = status {
            return true
        }
        return false
    }

    // MARK: - Engine error taxonomy

    /// The `.unavailable` message renders the provider-specific copy for
    /// every engine error the queue can surface.
    @Test("engine errors render their provider-specific status copy", arguments: [
        (TranslationEngineError.invalidKey, "Invalid API key. Check the key in Settings, then retry."),
        (TranslationEngineError.quotaExceeded, "The provider's API quota is exhausted. Retry later or switch provider."),
        (TranslationEngineError.rateLimited, "The provider is rate limiting requests. Retry shortly."),
        (TranslationEngineError.serverError(503), "Provider server error (503). Retry shortly."),
        (TranslationEngineError.badResponse("nope"), "The provider returned an unexpected response: nope"),
        (TranslationEngineError.network, "Network error reaching the provider. Check the connection, then retry."),
        (TranslationEngineError.cancelled, "Translation was cancelled.")
    ])
    func engineErrorCopy(error: TranslationEngineError, expected: String) async {
        let engine = ThrowingEngine(handler: { throw error })

        let message = await unavailableMessage(engine: engine)

        #expect(message == expected)
    }

    // MARK: - Translation framework errors

    /// A `TranslationError` from the on-device engine renders its localized
    /// description (the notInstalled special case is gated below).
    @Test("a Translation framework error renders its localized description")
    func translationFrameworkErrorRendersCopy() async {
        let engine = ThrowingEngine(handler: { throw TranslationError.nothingToTranslate })

        let message = await unavailableMessage(engine: engine)

        #expect(
            message == TranslationError.nothingToTranslate.errorDescription ?? "Translation failed."
        )
    }

    /// macOS 26 added the notInstalled special case with install guidance.
    @Test("a missing translation pack renders the install guidance")
    func notInstalledRendersInstallCopy() async throws {
        guard #available(macOS 26.0, *) else {
            try Test.cancel("TranslationError.notInstalled requires macOS 26")
        }
        let engine = ThrowingEngine(handler: { throw TranslationError.notInstalled })

        let message = await unavailableMessage(engine: engine)

        #expect(
            message == "The ja→en translation pack is not installed. Allow the download "
                + "prompt (or install it in System Settings), then retry."
        )
    }

    // MARK: - Unknown errors

    /// Anything unrecognized falls back to the localized description.
    @Test("an unknown error renders the generic copy")
    func unknownErrorRendersGenericCopy() async {
        struct ExplodingError: Error, Sendable {}
        let unknown = ExplodingError()
        let engine = ThrowingEngine(handler: { throw unknown })

        let message = await unavailableMessage(engine: engine)

        #expect(message == "Translation failed: \(unknown.localizedDescription)")
    }
}
