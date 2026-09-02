import Foundation
@testable import Mimi
import Testing
@preconcurrency import Translation

/// Tests `AppModel`'s translation pipeline end-to-end over the real OS ja→en
/// pack: a sentence surfaced through `sessionController.onSentence` is
/// enqueued by the model's own wiring, translated by a worker attached to a
/// real `TranslationSession`, and lands in `entries` through the queue's
/// result handler; a repeat of the same text resolves from the enqueue cache
/// synchronously. macOS 26+ with the pack installed (`Test.cancel`
/// otherwise).
@MainActor
@Suite("AppModel translation pipeline")
struct AppModelTranslationTests {

    // MARK: - Fixtures

    private let sentenceText = "テスト"
    /// First translate loads the pack model; generous for slow machines.
    private let resultTimeout: TimeInterval = 20

    private func makeSentence(index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
    }

    private func makeInstalledJAToENSession() async throws -> TranslationSession {
        guard #available(macOS 26.0, *) else {
            try Test.cancel("TranslationSession(installedSource:) requires macOS 26")
        }
        guard await TestEnvironment.jaToENPackInstalled() else {
            try Test.cancel("ja→en translation pack is not installed")
        }
        return TranslationSession(
            installedSource: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: "en")
        )
    }

    /// Bounded poll for a condition; gives up after `timeout` so a stalled
    /// pipeline fails the assertions instead of hanging the suite.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Delivery

    @Test("a sentence flows through the queue into the transcript with its translation")
    func sentenceFlowsThroughQueueIntoEntries() async throws {
        let session = try await makeInstalledJAToENSession()
        let model = AppModel()
        let worker = Task { await model.translationQueue.run(with: AppleSessionEngine(session)) }
        defer { worker.cancel() }

        model.sessionController.onSentence?(makeSentence(index: 0, text: sentenceText))

        await waitUntil(timeout: resultTimeout) {
            !(model.entries.first?.translations.isEmpty ?? true)
        }
        let translation = try #require(model.entries.first?.translations.first)
        #expect(translation.lang == "en")
        #expect(!translation.text.isEmpty)
        #expect(model.entries[0].joinedTranslations == translation.text)
        #expect(model.translationStatus == .ready)
    }

    // MARK: - Enqueue cache

    /// The same text under a new index must resolve from the queue's cache at
    /// enqueue time — synchronously, with no second session round-trip.
    @Test("a repeat sentence resolves from the enqueue cache synchronously")
    func repeatSentenceHitsCacheSynchronously() async throws {
        let session = try await makeInstalledJAToENSession()
        let model = AppModel()
        let worker = Task { await model.translationQueue.run(with: AppleSessionEngine(session)) }
        defer { worker.cancel() }

        model.sessionController.onSentence?(makeSentence(index: 0, text: sentenceText))
        await waitUntil(timeout: resultTimeout) {
            !(model.entries.first?.translations.isEmpty ?? true)
        }

        model.sessionController.onSentence?(makeSentence(index: 1, text: sentenceText))

        #expect(model.entries.count == 2)
        #expect(
            model.entries[1].translations == model.entries[0].translations,
            "same text must resolve from the cache without a second round-trip"
        )
    }
}
