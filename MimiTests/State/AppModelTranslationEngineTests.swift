import Foundation
@testable import Mimi
import Synchronization
import Testing

/// Tests `AppModel`'s engine selection: an external provider spawns a
/// worker task (config stays nil), an exhausted external engine latches the
/// one-way Apple fallback per session, a manual retry resets the latch (the
/// next failure re-latches instead of parking on `.unavailable`), and an
/// unconfigured selected provider degrades to Apple with a note.
@MainActor
@Suite("AppModel engine selection + fallback")
struct AppModelTranslationEngineTests {

    // MARK: - Fixtures

    private let resultTimeout: TimeInterval = 5

    private func makeSentence(index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
    }

    private func makeSettings(provider: TranslationProvider) -> TranslationSettings {
        let settings = isolatedTranslationSettings(suite: "test.AppModelEngine")
        if provider != .apple {
            // Saving a key for an external provider auto-selects it.
            try? settings.saveKey("test-key-1234", for: provider)
        }
        return settings
    }

    /// Transport that always answers with the given HTTP status (a failing
    /// engine without retry-inducing latency: 401 is non-transient).
    private func constantStatusTransport(_ status: Int) -> HTTPTranslationTransport {
        HTTPTranslationTransport(timeout: 5) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
    }

    /// Tears the model's translation worker down (stop requires a session
    /// phase; the queue worker is what actually needs cancelling).
    private func stopTranslation(_ model: AppModel) async {
        model.phase = .running
        model.stop()
        #expect(await pollUntil(timeout: 5) { model.phase == .idle }, "stop() winds the phase down to idle")
    }

    // MARK: - Engine selection

    @Test("an external provider spawns a worker and parks the Apple host")
    func externalProviderSpawnsWorkerWithoutConfig() async {
        let model = AppModel(
            translationSettings: makeSettings(provider: .openrouter),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelEngine"),
            translationTransport: constantStatusTransport(500),
            initialModelResolve: { _ in nil }
        )

        model.retryTranslation()
        #expect(await pollUntil { model.translationStatus == .ready }, "retryTranslation publishes .ready")

        #expect(model.activeTranslationEngine == .external)
        #expect(model.translationConfig == nil)

        await stopTranslation(model)
    }

    @Test("an unconfigured selected provider degrades to Apple")
    func unconfiguredProviderFallsBackToApple() {
        let settings = isolatedTranslationSettings(suite: "test.AppModelEngine")
        settings.select(.openrouter)
        let model = AppModel(
            translationSettings: settings,
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelEngine"),
            initialModelResolve: { _ in nil }
        )

        model.retryTranslation()

        #expect(model.activeTranslationEngine == .apple)
        #expect(model.translationConfig != nil)
    }

    @Test("each external provider builds its engine and spawns the worker")
    func eachExternalProviderBuildsItsEngine() async {
        for provider in [TranslationProvider.google, .deepl] {
            let model = AppModel(
                translationSettings: makeSettings(provider: provider),
                asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelEngine"),
                translationTransport: constantStatusTransport(401),
                initialModelResolve: { _ in nil }
            )

            model.retryTranslation()
            #expect(
                await pollUntil { model.translationStatus == .ready },
                "retryTranslation publishes .ready (\(provider))"
            )

            #expect(model.activeTranslationEngine == .external, "\(provider)")
            #expect(model.translationConfig == nil, "\(provider)")

            await stopTranslation(model)
        }
    }

    // MARK: - Latched auto-fallback

    @Test("an exhausted external engine latches Apple fallback with a degraded status")
    func externalFailureLatchesAppleFallback() async {
        let model = AppModel(
            translationSettings: makeSettings(provider: .openrouter),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelEngine"),
            translationTransport: constantStatusTransport(401),
            initialModelResolve: { _ in nil }
        )

        model.retryTranslation()
        #expect(model.activeTranslationEngine == .external)
        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))

        #expect(await pollUntil { model.translationFallbackActive }, "the exhausted engine latches the Apple fallback")

        #expect(model.translationFallbackActive)
        #expect(model.activeTranslationEngine == .apple)
        #expect(model.translationConfig != nil, "the Apple host must be re-activated")
        #expect(
            model.translationStatus
                == .degraded("External translation failed — using Apple on-device", .permanent)
        )
        // The degraded card carries the Retry affordance; it must survive the
        // fresh Apple run's `.ready` while the latch is active.
        let fallbackToast = model.toasts.toasts.first { $0.key == ToastKey.translationFallback }
        #expect(fallbackToast?.style == .yellowPersistent)
        #expect(fallbackToast?.action?.label == "Retry")

        await stopTranslation(model)
    }

    /// Every manual retry resets `translationFallbackActive`, so a
    /// failure after a retry re-latches onto Apple instead of parking on
    /// `.unavailable` forever.
    @Test("a manual retry re-arms the one-way fallback latch")
    func manualRetryRearmsFallbackLatch() async {
        let model = AppModel(
            translationSettings: makeSettings(provider: .openrouter),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelEngine"),
            translationTransport: constantStatusTransport(401),
            initialModelResolve: { _ in nil }
        )

        // First failure: latches onto Apple.
        model.retryTranslation()
        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))
        #expect(await pollUntil { model.translationFallbackActive }, "the first failure latches the Apple fallback")

        // Manual retry resets the latch and re-attempts the external engine
        // (the key may have been fixed).
        model.retryTranslation()
        #expect(!model.translationFallbackActive, "the retry re-arms the fallback")
        #expect(model.activeTranslationEngine == .external)

        // A second failure re-latches instead of parking on .unavailable.
        model.translationQueue.enqueue(makeSentence(index: 1, text: "こんにちは"))
        #expect(
            await pollUntil { model.translationFallbackActive },
            "the retried failure re-latches the Apple fallback"
        )
        #expect(model.activeTranslationEngine == .apple, "no parking on .unavailable")
        #expect(model.translationConfig != nil, "the Apple host is re-activated again")

        await stopTranslation(model)
    }

    // MARK: - Retry progress wiring

    /// The engine's `onRetry` is wired to `queue.noteRetry`: a transient
    /// failure surfaces `.retrying` with the footer copy and resolves back
    /// to `.ready` when the retried attempt succeeds.
    @Test("engine retry progress surfaces as .retrying and resolves to ready")
    func engineRetryProgressSurfacesAsRetrying() async {
        // First round-trip 429 (transient → one retry), then a valid
        // chat-completions response.
        let attempts = Mutex(0)
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            let attempt = attempts.withLock { state -> Int in
                state += 1
                return state
            }
            let status = attempt == 1 ? 429 : 200
            let body = attempt == 1
                ? Data()
                : Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }
        let model = AppModel(
            translationSettings: makeSettings(provider: .openrouter),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelEngine"),
            translationTransport: transport,
            initialModelResolve: { _ in nil }
        )
        let recorder = TextRecorder()
        var statuses: [TranslationStatus] = []
        // Replace AppModel's wiring with an observation tap: results land in
        // a local recorder (no transcript entries exist in this test) and
        // statuses keep flowing through the model.
        model.translationQueue.setHandlers(
            result: { _, translation in recorder.record(translation.text) },
            status: { [weak model] status in
                statuses.append(status)
                model?.handleTranslationStatus(status)
            }
        )

        model.retryTranslation()
        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))

        // The queue publishes .ready after the result; poll on the status so
        // the assertions below observe the settled sequence.
        #expect(await pollUntil { statuses.last == .ready }, "the retried attempt resolves back to ready")

        #expect(recorder.texts == ["hello"])
        #expect(
            statuses.contains(.retrying("External translation failed, 2 retries left")),
            "statuses were \(statuses)"
        )
        #expect(statuses.last == .ready)

        await stopTranslation(model)
    }

    /// Thread-safe text sink for result handlers.
    private final class TextRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []

        func record(_ text: String) {
            lock.withLock { log.append(text) }
        }

        var texts: [String] {
            lock.withLock { log }
        }
    }
}
