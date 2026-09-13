import AppKit
import Foundation
@testable import Mimi
import Testing

/// Tests the `AppModel` export surface (`AppModelExport`): exportability,
/// the copy commands, and delegation to `SessionExporter` for all four
/// formats. Split from `AppModelTests` alongside the production extension.
/// The JSON metadata-passthrough test begins a session over injected
/// engine/capture/permission doubles; everything else runs against default
/// factories with a stubbed model check.
@MainActor
@Suite("AppModel export")
struct AppModelExportTests {

    // MARK: - Fixtures

    private let sentenceText = "テスト"
    private let translationText = "Test"

    // MARK: - Helpers

    private func makeSUT() async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelExport"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelExport"),
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return model
    }

    private func makeSentence(index: Int = 0) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: sentenceText)
    }

    /// Minimal engine double so `SessionController.begin()` runs without the
    /// native runtime; no polling behavior is needed for export tests.
    private final class BeginOnlyEngine: ASREngine, @unchecked Sendable {
        let isMock = true
        var onEngineError: ((String) -> Void)?
        var processedSamples = 0
        var pushedSamples = 0
        func prepare() {}
        func openStream() {}
        func push(_ samples: [Float]) {}
        func poll() -> ASREvent? {
            nil
        }

        func finish() -> [ASREvent] {
            []
        }
    }

    /// Minimal capture double: `begin()` starts it once and export never
    /// touches the stream again.
    private final class BeginOnlyCapture: AudioCapturing, @unchecked Sendable {
        var onChunk: ((AudioChunk) -> Void)?
        var onIOError: ((CaptureError) -> Void)?
        func start() async throws {}
        func stop() {}
    }

    /// A model whose session has begun (injected engine/capture/permission
    /// doubles), so `sessionController.sessionMetadata` is populated for the
    /// JSON-export passthrough test.
    private func makeBeganModel() async throws -> AppModel {
        let engine = BeginOnlyEngine()
        let capture = BeginOnlyCapture()
        let model = AppModel(
            makeSessionController: { live, latency, _, translationQueue in
                SessionController(
                    live: live, latency: latency, translationQueue: translationQueue,
                    makeEngine: { _, _ in engine },
                    makeCapture: { capture },
                    ensurePermission: { true },
                    warmUpEnabled: { false }
                )
            },
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelExport"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelExport"),
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        try await model.sessionController.begin(
            modelURL: URL(fileURLWithPath: "/tmp/model.gguf"), modelID: "mock"
        )
        return model
    }

    // MARK: - Exportability

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

    // MARK: - Copy commands

    @Test("exportText delegates to the plain exporter")
    func exportTextDelegatesToPlainExporter() async {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence())
        model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: translationText)
        )

        let output = model.exportText()

        #expect(output == "00:00  \(sentenceText)\n00:00  \(translationText)\n")
    }

    @Test("copyTranscript puts the plain-text transcript on the pasteboard")
    func copyTranscriptPutsTranscriptOnPasteboard() async {
        let model = await makeSUT()
        model.sessionController.onSentence?(makeSentence())

        model.copyTranscript()

        #expect(NSPasteboard.general.string(forType: .string) == model.exportText())
    }

    @Test("copySnippet puts the snippet on the pasteboard and posts the notice")
    func copySnippetPutsSnippetOnPasteboardAndPostsNotice() async {
        let model = await makeSUT()

        model.copySnippet("こんにちは")

        #expect(NSPasteboard.general.string(forType: .string) == "こんにちは")
        #expect(model.notices.message == "Text copied")
    }

    // MARK: - Format delegation

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

    // MARK: - JSON export

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

    @Test("json export passes the session metadata through")
    func exportJsonPassesSessionMetadataThrough() async throws {
        let model = try await makeBeganModel()
        model.sessionController.onSentence?(makeSentence(index: 0))
        model.sessionController.onSentence?(makeSentence(index: 1))
        model.applyTranslation(index: 0, translation: SentenceTranslation(lang: "en", text: "First"))
        model.applyTranslation(
            index: 0, translation: SentenceTranslation(lang: "en", text: "First final")
        )
        model.applyTranslation(
            index: 1, translation: SentenceTranslation(lang: "en", text: "Second")
        )

        let data = try model.export(format: .json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(JSONSessionDocument.self, from: data)
        let metadata = try #require(model.sessionController.sessionMetadata)
        #expect(doc.schemaVersion == 1)
        #expect(doc.session.sourceLang == metadata.sourceLang)
        #expect(doc.session.targetLang == metadata.targetLang)
        #expect(doc.session.model == metadata.model)
        #expect(doc.session.chunkMS == metadata.chunkMS)
        #expect(
            abs(doc.session.startedAt.timeIntervalSince1970
                - metadata.startedAt.timeIntervalSince1970) < 1
        )
        #expect(doc.sentences.count == 2)
        #expect(doc.sentences[0].translations == [
            SentenceTranslation(lang: "en", text: "First"),
            SentenceTranslation(lang: "en", text: "First final")
        ])
        #expect(doc.sentences[1].translations == [
            SentenceTranslation(lang: "en", text: "Second")
        ])
    }
}
