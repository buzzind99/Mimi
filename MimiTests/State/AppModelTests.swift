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

    private func makeSUT() -> AppModel {
        AppModel()
    }

    private func makeSentence(index: Int = 0) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: sentenceText)
    }

    /// Lets any spawned teardown task finish before assertions.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - stop() guards

    @Test("stop is a no-op while idle")
    func stopWhenIdle() async {
        let model = makeSUT()
        model.phase = .idle

        model.stop()
        await settle()

        #expect(model.phase == .idle)
    }

    @Test("stop is a no-op while needs-model")
    func stopWhenNeedsModel() async {
        let model = makeSUT()
        model.phase = .needsModel

        model.stop()
        await settle()

        #expect(model.phase == .needsModel)
    }

    @Test("stop is a no-op after a failure")
    func stopWhenFailed() async {
        let model = makeSUT()
        model.phase = .failed("boom")

        model.stop()
        await settle()

        #expect(model.phase == .failed("boom"))
    }

    // MARK: - stop() teardown

    @Test("stop from starting cancels and winds down to idle")
    func stopCancelsStarting() async {
        let model = makeSUT()
        model.phase = .starting

        model.stop()

        #expect(model.phase == .stopping)
        await settle()
        #expect(model.phase == .idle)
    }

    @Test("stop from running winds down to idle and resets translation status")
    func stopWindsDownRunning() async {
        let model = makeSUT()
        model.phase = .running

        model.stop()

        #expect(model.phase == .stopping)
        await settle()
        #expect(model.phase == .idle)
        #expect(model.translationStatus == .idle)
    }

    @Test("stop after losing the source winds down to idle")
    func stopWindsDownSourceLost() async {
        let model = makeSUT()
        model.phase = .sourceLost

        model.stop()

        #expect(model.phase == .stopping)
        await settle()
        #expect(model.phase == .idle)
    }

    // MARK: - retryTranslation()

    @Test("retryTranslation creates a configuration when none exists")
    func retryCreatesConfigWhenNil() {
        let model = makeSUT()
        model.translationConfig = nil

        model.retryTranslation()

        #expect(model.translationConfig != nil)
    }

    @Test("retryTranslation replaces the existing configuration")
    func retryReassignsConfig() {
        let model = makeSUT()
        model.retryTranslation()

        model.retryTranslation()

        #expect(model.translationConfig != nil)
    }

    // MARK: - Sentence handling

    @Test("a sentence appends an entry and enqueues translation")
    func onSentenceAppendsAndEnqueues() async {
        let model = makeSUT()
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
    func onSentenceKeepsOrder() {
        let model = makeSUT()

        model.sessionController.onSentence?(makeSentence(index: 0))
        model.sessionController.onSentence?(makeSentence(index: 1))

        #expect(model.entries.map(\.sentence.index) == [0, 1])
    }

    // MARK: - applyTranslation(index:translation:)

    @Test("a translation appends to the entry with the matching index")
    func applyTranslationAppendsWhenKnown() {
        let model = makeSUT()
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
    func applyTranslationNoOpWhenUnknown() {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence(index: 7))

        model.applyTranslation(
            index: 99, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        #expect(model.entries[0].translations == [])
        #expect(model.entries[0].joinedTranslations == nil)
    }

    // MARK: - Capture errors

    @Test("a capture error while running marks the source lost")
    func onCaptureErrorMarksSourceLostWhenRunning() {
        let model = makeSUT()
        model.phase = .running

        model.sessionController.onCaptureError?("stream died")

        #expect(model.phase == .sourceLost)
        #expect(model.errorMessage == "stream died")
    }

    @Test("a capture error while starting marks the source lost")
    func onCaptureErrorMarksSourceLostWhenStarting() {
        let model = makeSUT()
        model.phase = .starting

        model.sessionController.onCaptureError?("stream died during start")

        #expect(model.phase == .sourceLost)
        #expect(model.errorMessage == "stream died during start")
    }

    @Test("a capture error while idle is ignored")
    func onCaptureErrorIgnoredWhenIdle() {
        let model = makeSUT()
        model.phase = .idle

        model.sessionController.onCaptureError?("stream died")

        #expect(model.phase == .idle)
        #expect(model.errorMessage == nil)
    }

    // MARK: - Export

    @Test("nothing is exportable without entries")
    func notExportableWhenEmpty() {
        let model = makeSUT()

        #expect(!model.isExportable)
    }

    @Test("entries make the session exportable")
    func exportableWhenEntriesExist() {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())

        #expect(model.isExportable)
    }

    @Test("exportText delegates to the plain exporter")
    func exportTextDelegatesToPlainExporter() {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        let output = model.exportText()

        #expect(output == SessionExporter.plainText(entries: model.entries))
    }

    @Test("txt export matches the plain exporter")
    func exportTxtMatchesPlainExporter() throws {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())

        let data = try model.export(format: .txt)

        #expect(data == Data(SessionExporter.plainText(entries: model.entries).utf8))
    }

    @Test("srt export matches the subtitle exporter")
    func exportSrtMatchesSubtitleExporter() throws {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        let data = try model.export(format: .srt)

        #expect(data == Data(SessionExporter.subtitles(entries: model.entries, format: .srt).utf8))
    }

    @Test("vtt export matches the subtitle exporter")
    func exportVttMatchesSubtitleExporter() throws {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        let data = try model.export(format: .vtt)

        #expect(data == Data(SessionExporter.subtitles(entries: model.entries, format: .vtt).utf8))
    }

    @Test("json export falls back to defaults for nil session metadata")
    func exportJsonFallsBackForNilMetadata() throws {
        let model = makeSUT()
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
    func exportJsonSnapshotsLatestTranslation() throws {
        let model = makeSUT()
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
    func onSessionBeginClearsTranscriptState() {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.hudPinnedIndex = 3

        model.sessionController.onSessionBegin?()

        #expect(model.entries.isEmpty)
        #expect(model.hudPinnedIndex == nil)
    }

    @Test("engine chosen publishes the engine info")
    func onEngineChosenPublishesEngineInfo() {
        let model = makeSUT()
        let url = URL(fileURLWithPath: "/tmp/model.gguf")

        model.sessionController.onEngineChosen?(true, url)

        #expect(model.engineIsMock)
        #expect(model.modelURL == url)
    }

    @Test("engine error publishes the error message")
    func onEngineErrorPublishesErrorMessage() {
        let model = makeSUT()

        model.sessionController.onEngineError?("engine broke")

        #expect(model.errorMessage == "engine broke")
    }

    @Test("the translation queue status handler publishes the status")
    func translationQueueStatusHandlerPublishesStatus() {
        let model = makeSUT()
        model.translationStatus = .translating

        model.translationQueue.resetForRetry()

        #expect(model.translationStatus == .idle)
    }

    // MARK: - refreshModelAvailability / start() guards

    @Test("model discovery recovers a needs-model session when a model resolves")
    func refreshModelAvailabilityRecoversFromNeedsModel() {
        let model = makeSUT()
        model.phase = .needsModel

        model.refreshModelAvailability(resolve: { URL(fileURLWithPath: "/tmp/model.gguf") })

        #expect(model.phase == .idle)
    }

    @Test("model discovery marks needs-model when nothing resolves")
    func refreshModelAvailabilityNeedsModelWhenNothingResolves() {
        let model = makeSUT()
        model.phase = .idle

        model.refreshModelAvailability(resolve: { nil })

        #expect(model.phase == .needsModel)
    }

    @Test("start is a no-op when not idle")
    func startWhenNotIdleIsNoOp() {
        let model = makeSUT()
        model.phase = .running

        model.start()

        #expect(model.phase == .running)
    }

    // MARK: - App termination

    @Test("the app-terminate notification stops a running session")
    func terminateNotificationStopsRunningSession() async {
        let model = makeSUT()
        model.phase = .running

        NotificationCenter.default.post(name: Self.willTerminateNotification, object: nil)
        await settle()

        #expect(model.phase == .idle)
    }

    private static let willTerminateNotification = NSNotification.Name("MimiAppWillTerminate")
}
