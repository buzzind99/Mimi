import Foundation
@testable import Mimi
import Testing

/// Tests `AppModel`'s engine selection: an external provider spawns a
/// worker task (config stays nil), an exhausted external engine latches the
/// one-way Apple fallback per session, the latch survives manual retries,
/// and an unconfigured selected provider degrades to Apple with a note.
@MainActor
@Suite("AppModel engine selection + fallback")
struct AppModelTranslationEngineTests {

    // MARK: - Fixtures

    private let resultTimeout: TimeInterval = 5

    private func makeSentence(index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
    }

    private func makeSettings(provider: TranslationProvider) -> TranslationSettings {
        let defaults = UserDefaults(suiteName: "test.AppModelEngine.\(UUID().uuidString)")!
        let settings = TranslationSettings(defaults: defaults, keys: InMemoryKeyStore())
        if provider == .apple {
            settings.select(.apple)
        } else {
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

    private func waitUntil(
        timeout: TimeInterval = 5, _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Tears the model's translation worker down (stop requires a session
    /// phase; the queue worker is what actually needs cancelling).
    private func stopTranslation(_ model: AppModel) async {
        model.phase = .running
        model.stop()
        await waitUntil { model.phase == .idle }
    }

    // MARK: - Engine selection

    @Test("an external provider spawns a worker and parks the Apple host")
    func externalProviderSpawnsWorkerWithoutConfig() async {
        let model = AppModel(
            translationSettings: makeSettings(provider: .openrouter),
            translationTransport: constantStatusTransport(500),
            initialModelResolve: { nil }
        )

        model.retryTranslation()
        await waitUntil { model.translationStatus == .ready }

        #expect(model.activeTranslationEngine == .external)
        #expect(model.translationConfig == nil)

        await stopTranslation(model)
    }

    @Test("an unconfigured selected provider degrades to Apple with a note")
    func unconfiguredProviderFallsBackToAppleWithNote() throws {
        let defaults = try #require(
            UserDefaults(suiteName: "test.AppModelEngine.\(UUID().uuidString)")
        )
        let settings = TranslationSettings(defaults: defaults, keys: InMemoryKeyStore())
        settings.select(.openrouter)
        let model = AppModel(translationSettings: settings, initialModelResolve: { nil })

        model.retryTranslation()

        #expect(model.activeTranslationEngine == .apple)
        #expect(model.translationConfig != nil)
        #expect(model.errorMessage?.contains("no API key") == true)
    }

    @Test("each external provider builds its engine and spawns the worker")
    func eachExternalProviderBuildsItsEngine() async {
        for provider in [TranslationProvider.google, .deepl] {
            let model = AppModel(
                translationSettings: makeSettings(provider: provider),
                translationTransport: constantStatusTransport(401),
                initialModelResolve: { nil }
            )

            model.retryTranslation()
            await waitUntil { model.translationStatus == .ready }

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
            translationTransport: constantStatusTransport(401),
            initialModelResolve: { nil }
        )

        model.retryTranslation()
        #expect(model.activeTranslationEngine == .external)
        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))

        await waitUntil { model.translationFallbackActive }

        #expect(model.translationFallbackActive)
        #expect(model.activeTranslationEngine == .apple)
        #expect(model.translationConfig != nil, "the Apple host must be re-activated")
        #expect(
            model.translationStatus
                == .degraded("External translation failed — using Apple on-device")
        )

        await stopTranslation(model)
    }

    @Test("the fallback latch is one-way per session despite manual retries")
    func fallbackLatchSurvivesManualRetry() async {
        let model = AppModel(
            translationSettings: makeSettings(provider: .openrouter),
            translationTransport: constantStatusTransport(401),
            initialModelResolve: { nil }
        )

        // First failure: latches onto Apple.
        model.retryTranslation()
        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))
        await waitUntil { model.translationFallbackActive }

        // Manual retry re-attempts the external engine (key may be fixed).
        model.retryTranslation()
        #expect(model.activeTranslationEngine == .external)

        // A second failure must NOT re-enter the fallback: the latch is
        // one-way, so the dead external run stays surfaced for the button.
        model.translationQueue.enqueue(makeSentence(index: 1, text: "こんにちは"))
        await waitUntil(timeout: resultTimeout) {
            if case .unavailable = model.translationStatus {
                return true
            }
            return false
        }

        #expect(model.translationFallbackActive, "the latch stays engaged")
        #expect(model.activeTranslationEngine == .external, "no second auto-fallback")
        guard case .unavailable = model.translationStatus else {
            Issue.record("expected .unavailable, got \(model.translationStatus)")
            return
        }

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
        let lock = NSLock()
        var attempts = 0
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            let attempt = lock.withLock {
                attempts += 1
                return attempts
            }
            let status = attempt == 1 ? 429 : 200
            let body = attempt == 1
                ? Data()
                : Data(#"{"choices":[{"message":{"content":"[\"hello\"]"}}]}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }
        let model = AppModel(
            translationSettings: makeSettings(provider: .openrouter),
            translationTransport: transport,
            initialModelResolve: { nil }
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

        await waitUntil { !recorder.texts.isEmpty }

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
