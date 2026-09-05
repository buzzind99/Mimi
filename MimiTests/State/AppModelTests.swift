import AppKit
import Foundation
@testable import Mimi
import Testing

/// Tests `AppModel` session-control guards, translation wiring, and export
/// delegation on the main actor. The `start()`/`begin()` flow itself is
/// covered over injected factories in `AppModelSessionTests`; the default
/// factories (real TCC preflight + SCK) stay production-only here.
@MainActor
@Suite("AppModel session control")
struct AppModelTests {

    // MARK: - Fixtures

    private let sentenceText = "テスト"
    private let translationText = "Test"

    // MARK: - Helpers

    /// Awaits the launch-time model check so phase assertions are
    /// deterministic. The check itself is stubbed (`initialModelResolve`):
    /// the real locator SHA-256-hashes the dev GGUF and feeds the engine
    /// warm-up — real blocking work that starves the cooperative pool under
    /// parallel test execution. Flow coverage over scripted doubles lives in
    /// `AppModelSessionTests`.
    private func makeSUT() async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelControl"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelControl"),
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return model
    }

    private func makeSentence(index: Int = 0) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: sentenceText)
    }

    // MARK: - stop() guards

    @Test("stop is a no-op while idle")
    func stopWhenIdle() async {
        let model = await makeSUT()
        model.phase = .idle

        model.stop()

        #expect(model.phase == .idle)
    }

    @Test("stop is a no-op while needs-model")
    func stopWhenNeedsModel() async {
        let model = await makeSUT()
        model.phase = .needsModel

        model.stop()

        #expect(model.phase == .needsModel)
    }

    @Test("stop is a no-op after a failure")
    func stopWhenFailed() async {
        let model = await makeSUT()
        model.phase = .failed("boom")

        model.stop()

        #expect(model.phase == .failed("boom"))
    }

    // MARK: - stop() teardown

    @Test("stop from starting cancels and winds down to idle")
    func stopCancelsStarting() async {
        let model = await makeSUT()
        model.phase = .starting

        model.stop()

        #expect(model.phase == .stopping)
        #expect(await pollUntil { model.phase == .idle }, "stop winds down to idle")
    }

    @Test("stop from running winds down to idle and resets translation status")
    func stopWindsDownRunning() async {
        let model = await makeSUT()
        model.phase = .running

        model.stop()

        #expect(model.phase == .stopping)
        #expect(await pollUntil { model.phase == .idle }, "stop winds down to idle")
        #expect(model.translationStatus == .idle)
    }

    @Test("stop after losing the source winds down to idle")
    func stopWindsDownSourceLost() async {
        let model = await makeSUT()
        model.phase = .sourceLost

        model.stop()

        #expect(model.phase == .stopping)
        #expect(await pollUntil { model.phase == .idle }, "stop winds down to idle")
    }

    // MARK: - retryTranslation()

    @Test("retryTranslation creates a configuration when none exists")
    func retryCreatesConfigWhenNil() async {
        let model = await makeSUT()
        model.translationConfig = nil

        model.retryTranslation()

        #expect(model.translationConfig != nil)
    }

    @Test("retryTranslation replaces the existing configuration")
    func retryReassignsConfig() async {
        let model = await makeSUT()
        model.retryTranslation()

        model.retryTranslation()

        #expect(model.translationConfig != nil)
    }

    // MARK: - Sentence handling

    @Test("a sentence appends an entry and enqueues translation")
    func onSentenceAppendsAndEnqueues() async {
        let model = await makeSUT()
        let sentence = makeSentence()

        model.sessionController.onSentence?(sentence)

        #expect(model.entries.count == 1)
        #expect(model.entries.first?.sentence == sentence)
        // The queue holds the untranslated sentence, so a bounded drain
        // times out instead of completing immediately.
        let drained = await model.translationQueue.drain(timeout: 0.05)
        #expect(!drained)
    }

    @Test("sentences append in arrival order")
    func onSentenceKeepsOrder() async {
        let model = await makeSUT()

        model.sessionController.onSentence?(makeSentence(index: 0))
        model.sessionController.onSentence?(makeSentence(index: 1))

        #expect(model.entries.map(\.sentence.index) == [0, 1])
    }

    // MARK: - applyTranslation(index:translation:)

    @Test("a translation appends to the entry with the matching index")
    func applyTranslationAppendsWhenKnown() async {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence(index: 7))

        model.applyTranslation(
            index: 7, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        #expect(model.entries[0].translations == [
            SentenceTranslation(lang: "en", text: translationText)
        ])
        #expect(model.entries[0].joinedTranslations == translationText)
    }

    @Test("a translation for an unknown index is ignored")
    func applyTranslationNoOpWhenUnknown() async {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence(index: 7))

        model.applyTranslation(
            index: 99, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        #expect(model.entries[0].translations == [])
        #expect(model.entries[0].joinedTranslations == nil)
    }

    // MARK: - Capture errors

    @Test("a capture error while running marks the source lost and posts the capture.lost toast")
    func onCaptureErrorMarksSourceLostWhenRunning() async {
        let model = await makeSUT()
        model.phase = .running

        model.sessionController.onCaptureError?("stream died")

        #expect(model.phase == .sourceLost)
        let toast = model.toasts.toasts.first { $0.key == ToastKey.captureLost }
        #expect(toast?.style == .redPersistent)
        #expect(toast?.body == "stream died")
        #expect(toast?.action?.label == "Restart capture")
    }

    @Test("a capture error while starting marks the source lost and posts the capture.lost toast")
    func onCaptureErrorMarksSourceLostWhenStarting() async {
        let model = await makeSUT()
        model.phase = .starting

        model.sessionController.onCaptureError?("stream died during start")

        #expect(model.phase == .sourceLost)
        #expect(
            model.toasts.toasts.contains {
                $0.key == ToastKey.captureLost && $0.body == "stream died during start"
            }
        )
    }

    @Test("a capture error while idle is ignored")
    func onCaptureErrorIgnoredWhenIdle() async {
        let model = await makeSUT()
        model.phase = .idle

        model.sessionController.onCaptureError?("stream died")

        #expect(model.phase == .idle)
        #expect(model.toasts.toasts.isEmpty)
    }

    // MARK: - Export

    @Test("nothing is exportable without entries")
    func notExportableWhenEmpty() async {
        let model = await makeSUT()

        #expect(!model.isExportable)
    }

    @Test("entries make the session exportable")
    func exportableWhenEntriesExist() async {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence())

        #expect(model.isExportable)
    }

    @Test("exportText delegates to the plain exporter")
    func exportTextDelegatesToPlainExporter() async {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        let output = model.exportText()

        #expect(output == SessionExporter.plainText(entries: model.entries))
    }

    @Test("copyTranscript puts the plain-text transcript on the pasteboard")
    func copyTranscriptPutsTranscriptOnPasteboard() async {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence())

        model.copyTranscript()

        #expect(NSPasteboard.general.string(forType: .string) == model.exportText())
    }

    @Test("txt export matches the plain exporter")
    func exportTxtMatchesPlainExporter() async throws {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence())

        let data = try model.export(format: .txt)

        #expect(data == Data(SessionExporter.plainText(entries: model.entries).utf8))
    }

    @Test("srt export matches the subtitle exporter")
    func exportSrtMatchesSubtitleExporter() async throws {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        let data = try model.export(format: .srt)

        #expect(data == Data(SessionExporter.subtitles(entries: model.entries, format: .srt).utf8))
    }

    @Test("vtt export matches the subtitle exporter")
    func exportVttMatchesSubtitleExporter() async throws {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        let data = try model.export(format: .vtt)

        #expect(data == Data(SessionExporter.subtitles(entries: model.entries, format: .vtt).utf8))
    }

    @Test("json export falls back to defaults for nil session metadata")
    func exportJsonFallsBackForNilMetadata() async throws {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence())

        let data = try model.export(format: .json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(JSONSessionDocument.self, from: data)
        #expect(doc.schemaVersion == 1)
        #expect(doc.session.sourceLang == "ja")
        #expect(doc.session.targetLang == "en")
        #expect(doc.session.model == nil)
        #expect(doc.session.chunkMS == 160)
        #expect(doc.sentences.count == 1)
        #expect(doc.sentences[0].index == 0)
        #expect(doc.sentences[0].transcript == sentenceText)
        #expect(doc.sentences[0].translations == [])
    }

    @Test("json export snapshots the latest translation")
    func exportJsonSnapshotsLatestTranslation() async throws {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        let data = try model.export(format: .json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(JSONSessionDocument.self, from: data)
        #expect(doc.sentences[0].translations == [
            SentenceTranslation(lang: "en", text: translationText)
        ])
    }

    // MARK: - Session controller wiring

    @Test("session begin clears the transcript state")
    func onSessionBeginClearsTranscriptState() async {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.hudPinnedIndex = 3

        model.sessionController.onSessionBegin?()

        #expect(model.entries.isEmpty)
        #expect(model.hudPinnedIndex == nil)
    }

    @Test("engine chosen publishes the engine info")
    func onEngineChosenPublishesEngineInfo() async {
        let model = await makeSUT()
        let url = URL(fileURLWithPath: "/tmp/model.gguf")

        model.sessionController.onEngineChosen?(true, url)

        #expect(model.engineIsMock)
        #expect(model.modelURL == url)
    }

    @Test("an engine error surfaces as an asr.warning toast")
    func onEngineErrorSurfacesAsWarningToast() async {
        let model = await makeSUT()

        model.sessionController.onEngineError?("engine broke")

        let toast = model.toasts.toasts.first { $0.key == ToastKey.asrWarning }
        #expect(toast?.style == .yellowAuto)
        #expect(toast?.body == "engine broke")
    }

    @Test("stop clears all toasts")
    func stopClearsToasts() async {
        let model = await makeSUT()
        model.phase = .running
        model.sessionController.onEngineError?("engine broke")
        #expect(!model.toasts.toasts.isEmpty)

        model.stop()
        #expect(await pollUntil { model.phase == .idle }, "stop winds down to idle")

        #expect(model.toasts.toasts.isEmpty)
    }

    @Test("the translation queue status handler publishes the status")
    func translationQueueStatusHandlerPublishesStatus() async {
        let model = await makeSUT()
        model.translationStatus = .translating

        model.translationQueue.resetForRetry()

        #expect(model.translationStatus == .idle)
    }

    // MARK: - refreshModelAvailability / start() guards

    @Test("model discovery recovers a needs-model session when a model resolves")
    func refreshModelAvailabilityRecoversFromNeedsModel() async {
        let model = await makeSUT()
        model.phase = .needsModel

        await model.refreshModelAvailability(resolve: { _ in URL(fileURLWithPath: "/tmp/model.gguf") })

        #expect(model.phase == .idle)
        #expect(!model.isCheckingModel)
    }

    @Test("model discovery marks needs-model when nothing resolves")
    func refreshModelAvailabilityNeedsModelWhenNothingResolves() async {
        let model = await makeSUT()
        model.phase = .idle

        await model.refreshModelAvailability(resolve: { _ in nil })

        #expect(model.phase == .needsModel)
        #expect(model.modelURL == nil)
        #expect(!model.isCheckingModel)
    }

    @Test("start is a no-op while the model check is in flight")
    func startWhileCheckingModelIsNoOp() async {
        let model = await makeSUT()
        model.phase = .idle
        // Park the check inside `resolve` so `isCheckingModel` stays live
        // until the gate opens: the flag can never flip back to false
        // between the wait and the `start()` assertion (a bare yield-spin
        // raced the check's completion and could spin forever).
        let gate = ModelCheckGate()
        let check = Task { await model.refreshModelAvailability(resolve: gate.resolve) }
        #expect(await pollUntil { model.isCheckingModel })

        model.start()

        #expect(model.phase == .idle)
        gate.open()
        await check.value
        #expect(!model.isCheckingModel)
    }

    @Test("start is a no-op when not idle")
    func startWhenNotIdleIsNoOp() async {
        let model = await makeSUT()
        model.phase = .running

        model.start()

        #expect(model.phase == .running)
    }

    // MARK: - App termination

    @Test("the app-terminate notification stops a running session")
    func terminateNotificationStopsRunningSession() async {
        // A private center: posting on the shared `.default` center would
        // stop every other live `AppModel` running in parallel tests.
        let notifications = NotificationCenter()
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelControl"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelControl"),
            initialModelResolve: { _ in nil },
            willTerminateNotifications: notifications
        )
        await model.initialModelCheck?.value
        model.phase = .running

        notifications.post(name: .mimiAppWillTerminate, object: nil)
        #expect(await pollUntil { model.phase == .idle }, "the terminate notification stops the session")
    }

    /// Gate parked inside the model check's `resolve`: keeps the check in
    /// flight (and `isCheckingModel` true) until the test opens it. Releases
    /// every waiter at once — the check fans `resolve` out over a task group
    /// (one child per choice), so multiple resolves can park concurrently.
    /// The wait is bounded so a regression surfaces as a failure, never a
    /// wedge. Same pattern as `AppModelSessionTests.StartGate`.
    private final class ModelCheckGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var isOpen = false

        /// Serves as the check's `resolve` (runs off-main in the detached
        /// task group): parks until `open()`, then reports no model found.
        func resolve(_ choice: ASRModelChoice) -> URL? {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(10)
            while !isOpen {
                guard condition.wait(until: deadline) else { break }
            }
            return nil
        }

        func open() {
            condition.lock()
            isOpen = true
            condition.broadcast()
            condition.unlock()
        }
    }
}
