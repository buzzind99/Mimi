@testable import Mimi
import XCTest

/// Tests `AppModel` session-control guards, translation wiring, and export
/// delegation on the main actor. `start()`/`begin()` are excluded: they
/// trigger the TCC Screen Recording prompt in the test host.
@MainActor
final class AppModelTests: XCTestCase {

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

    private func makeTranslatedEntry(index: Int = 0) -> SessionEntry {
        var entry = SessionEntry(sentence: makeSentence(index: index))
        entry.appendTranslation(SentenceTranslation(lang: "en", text: translationText))
        return entry
    }

    /// Lets any spawned teardown task finish before assertions.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - stop() guards

    func test_stop_whenIdle_shouldBeNoOp() async throws {
        let model = makeSUT()
        model.phase = .idle

        model.stop()
        try await settle()

        XCTAssertEqual(model.phase, .idle)
    }

    func test_stop_whenNeedsModel_shouldBeNoOp() async throws {
        let model = makeSUT()
        model.phase = .needsModel

        model.stop()
        try await settle()

        XCTAssertEqual(model.phase, .needsModel)
    }

    func test_stop_whenFailed_shouldBeNoOp() async throws {
        let model = makeSUT()
        model.phase = .failed("boom")

        model.stop()
        try await settle()

        XCTAssertEqual(model.phase, .failed("boom"))
    }

    // MARK: - stop() teardown

    func test_stop_whenStarting_shouldCancelAndWindDownToIdle() async throws {
        let model = makeSUT()
        model.phase = .starting

        model.stop()

        XCTAssertEqual(model.phase, .stopping)
        try await settle()
        XCTAssertEqual(model.phase, .idle)
    }

    func test_stop_whenRunning_shouldWindDownToIdle() async throws {
        let model = makeSUT()
        model.phase = .running

        model.stop()

        XCTAssertEqual(model.phase, .stopping)
        try await settle()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.translationStatus, .idle)
    }

    func test_stop_whenSourceLost_shouldWindDownToIdle() async throws {
        let model = makeSUT()
        model.phase = .sourceLost

        model.stop()

        XCTAssertEqual(model.phase, .stopping)
        try await settle()
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: - retryTranslation()

    func test_retryTranslation_whenConfigNil_shouldCreateConfig() {
        let model = makeSUT()
        model.translationConfig = nil

        model.retryTranslation()

        XCTAssertNotNil(model.translationConfig)
    }

    func test_retryTranslation_whenConfigPresent_shouldReassignConfig() {
        let model = makeSUT()
        model.retryTranslation()

        model.retryTranslation()

        XCTAssertNotNil(model.translationConfig)
    }

    // MARK: - Sentence handling

    func test_onSentence_shouldAppendEntryAndEnqueueTranslation() async {
        let model = makeSUT()
        let sentence = makeSentence()

        model.sessionController.onSentence?(sentence)

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.sentence, sentence)
        // The queue holds the untranslated sentence, so a bounded drain
        // times out instead of completing immediately.
        let drained = await model.translationQueue.drain(timeout: 0.05)
        XCTAssertFalse(drained)
    }

    func test_onSentence_whenTwoSentences_shouldKeepOrder() {
        let model = makeSUT()

        model.sessionController.onSentence?(makeSentence(index: 0))
        model.sessionController.onSentence?(makeSentence(index: 1))

        XCTAssertEqual(model.entries.map(\.sentence.index), [0, 1])
    }

    // MARK: - applyTranslation(index:translation:)

    func test_applyTranslation_whenIndexKnown_shouldAppendTranslation() {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence(index: 7))

        model.applyTranslation(
            index: 7, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        XCTAssertEqual(model.entries[0].translations, [
            SentenceTranslation(lang: "en", text: translationText)
        ])
        XCTAssertEqual(model.entries[0].joinedTranslations, translationText)
    }

    func test_applyTranslation_whenIndexUnknown_shouldBeNoOp() {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence(index: 7))

        model.applyTranslation(
            index: 99, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        XCTAssertEqual(model.entries[0].translations, [])
        XCTAssertNil(model.entries[0].joinedTranslations)
    }

    // MARK: - Capture errors

    func test_onCaptureError_whenRunning_shouldMarkSourceLost() {
        let model = makeSUT()
        model.phase = .running

        model.sessionController.onCaptureError?("stream died")

        XCTAssertEqual(model.phase, .sourceLost)
        XCTAssertEqual(model.errorMessage, "stream died")
    }

    func test_onCaptureError_whenStarting_shouldMarkSourceLost() {
        let model = makeSUT()
        model.phase = .starting

        model.sessionController.onCaptureError?("stream died during start")

        XCTAssertEqual(model.phase, .sourceLost)
        XCTAssertEqual(model.errorMessage, "stream died during start")
    }

    func test_onCaptureError_whenIdle_shouldBeIgnored() {
        let model = makeSUT()
        model.phase = .idle

        model.sessionController.onCaptureError?("stream died")

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - Export

    func test_isExportable_whenNoEntries_shouldBeFalse() {
        let model = makeSUT()

        XCTAssertFalse(model.isExportable)
    }

    func test_isExportable_whenEntriesExist_shouldBeTrue() {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())

        XCTAssertTrue(model.isExportable)
    }

    func test_exportText_shouldDelegateToPlainExporter() {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        let output = model.exportText()

        XCTAssertEqual(output, SessionExporter.plainText(entries: model.entries))
    }

    func test_export_whenTxt_shouldMatchPlainExporter() throws {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())

        let data = try model.export(format: .txt)

        XCTAssertEqual(data, Data(SessionExporter.plainText(entries: model.entries).utf8))
    }

    func test_export_whenSrt_shouldMatchSubtitleExporter() throws {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        let data = try model.export(format: .srt)

        XCTAssertEqual(
            data, Data(SessionExporter.subtitles(entries: model.entries, format: .srt).utf8)
        )
    }

    func test_export_whenVtt_shouldMatchSubtitleExporter() throws {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        let data = try model.export(format: .vtt)

        XCTAssertEqual(
            data, Data(SessionExporter.subtitles(entries: model.entries, format: .vtt).utf8)
        )
    }

    func test_export_whenJson_shouldFallBackForNilMetadata() throws {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())

        let data = try model.export(format: .json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(SessionExporter.JSONSessionDocument.self, from: data)
        XCTAssertEqual(doc.schemaVersion, 1)
        XCTAssertEqual(doc.session.sourceLang, "ja")
        XCTAssertEqual(doc.session.targetLang, "en")
        XCTAssertNil(doc.session.model)
        XCTAssertEqual(doc.session.chunkMS, 160)
        XCTAssertEqual(doc.sentences.count, 1)
        XCTAssertEqual(doc.sentences[0].index, 0)
        XCTAssertEqual(doc.sentences[0].transcript, sentenceText)
        XCTAssertEqual(doc.sentences[0].translations, [])
    }

    func test_export_whenJson_shouldSnapshotLatestTranslation() throws {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        let data = try model.export(format: .json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(SessionExporter.JSONSessionDocument.self, from: data)
        XCTAssertEqual(doc.sentences[0].translations, [
            SentenceTranslation(lang: "en", text: translationText)
        ])
    }

    // MARK: - Session controller wiring

    func test_onSessionBegin_shouldClearTranscriptState() {
        let model = makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.hudPinnedIndex = 3

        model.sessionController.onSessionBegin?()

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.hudPinnedIndex)
    }

    func test_onEngineChosen_shouldPublishEngineInfo() {
        let model = makeSUT()
        let url = URL(fileURLWithPath: "/tmp/model.gguf")

        model.sessionController.onEngineChosen?(true, url)

        XCTAssertTrue(model.engineIsMock)
        XCTAssertEqual(model.modelURL, url)
    }

    func test_onEngineError_shouldPublishErrorMessage() {
        let model = makeSUT()

        model.sessionController.onEngineError?("engine broke")

        XCTAssertEqual(model.errorMessage, "engine broke")
    }

    func test_translationQueueStatusHandler_shouldPublishStatus() {
        let model = makeSUT()
        model.translationStatus = .translating

        model.translationQueue.resetForRetry()

        XCTAssertEqual(model.translationStatus, .idle)
    }

    // MARK: - refreshModelAvailability / start() guards

    func test_refreshModelAvailability_whenModelResolves_shouldRecoverFromNeedsModel() {
        let model = makeSUT()
        model.phase = .needsModel

        model.refreshModelAvailability()

        XCTAssertEqual(model.phase, .idle)
    }

    func test_start_whenNotIdle_shouldBeNoOp() {
        let model = makeSUT()
        model.phase = .running

        model.start()

        XCTAssertEqual(model.phase, .running)
    }

    // MARK: - App termination

    func test_appWillTerminateNotification_whenRunning_shouldStop() async throws {
        let model = makeSUT()
        model.phase = .running

        NotificationCenter.default.post(name: AppModelTests.willTerminateNotification, object: nil)
        try await settle()

        XCTAssertEqual(model.phase, .idle)
    }

    private static let willTerminateNotification = NSNotification.Name("MimiAppWillTerminate")
}
