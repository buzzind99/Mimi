@testable import Mimi
import XCTest

/// Tests the export formats through the public `SessionExporter` API:
/// plain text, SRT (comma ms), VTT (dot ms + header), and the JSON session
/// document (verified by decoding back).
final class SessionExporterTests: XCTestCase {

    // MARK: - Fixtures

    private let japaneseSentence = "今日はいい天気ですね。"
    private let englishTranslation = "Nice weather today."
    private let sentenceStart = 0.0
    private let sentenceEnd = 1.5
    private let expectedStartStamp = "00:00"
    private let expectedSrtTiming = "00:00:00,000 --> 00:00:01,500"
    private let expectedVttTiming = "00:00:00.000 --> 00:00:01.500"
    private let expectedVttHeader = "WEBVTT"
    private let schemaVersion = 1

    // MARK: - Helpers

    private func makeTranslatedEntry() -> SessionEntry {
        var entry = makeUntranslatedEntry()
        entry.appendTranslation(SentenceTranslation(lang: "en", text: englishTranslation))
        return entry
    }

    private func makeUntranslatedEntry() -> SessionEntry {
        let sentence = Sentence(
            index: 0, startS: sentenceStart, endS: sentenceEnd, lang: "ja", text: japaneseSentence
        )
        return SessionEntry(sentence: sentence)
    }

    private func decodeDocument(from data: Data) throws -> SessionExporter.JSONSessionDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionExporter.JSONSessionDocument.self, from: data)
    }

    // MARK: - Plain text

    func test_plainText_whenInterleavedWithTranslation_shouldPrefixTimestampsOnBothLines() {
        let entry = makeTranslatedEntry()

        let output = SessionExporter.plainText(entries: [entry])

        XCTAssertEqual(
            output, "\(expectedStartStamp)  \(japaneseSentence)\n\(expectedStartStamp)  \(englishTranslation)\n"
        )
    }

    func test_plainText_whenUntranslated_shouldOmitTranslationLines() {
        let entry = makeUntranslatedEntry()

        let output = SessionExporter.plainText(entries: [entry])

        XCTAssertEqual(output, "\(expectedStartStamp)  \(japaneseSentence)\n")
    }

    // MARK: - SRT

    func test_subtitles_whenSrt_shouldUseCommaMilliseconds() {
        let entry = makeTranslatedEntry()
        let expectedCue = "1\n\(expectedSrtTiming)\n\(englishTranslation)\n\n"

        let output = SessionExporter.subtitles(entries: [entry], format: .srt)

        XCTAssertEqual(output, expectedCue)
    }

    func test_subtitles_whenEntryUntranslated_shouldSkipCue() {
        let entry = makeUntranslatedEntry()

        let output = SessionExporter.subtitles(entries: [entry], format: .srt)

        XCTAssertEqual(output, "")
    }

    // MARK: - VTT

    func test_subtitles_whenVtt_shouldUseHeaderAndDotMilliseconds() {
        let entry = makeTranslatedEntry()
        let expectedCue = "\(expectedVttHeader)\n\n1\n\(expectedVttTiming)\n\(englishTranslation)\n\n"

        let output = SessionExporter.subtitles(entries: [entry], format: .vtt)

        XCTAssertEqual(output, expectedCue)
    }

    // MARK: - JSON session

    func test_json_whenEncoded_shouldDeclareSchemaVersion() throws {
        let entry = makeTranslatedEntry()

        let data = try SessionExporter.json(entries: [entry], metadata: nil, results: [:])
        let document = try decodeDocument(from: data)

        XCTAssertEqual(document.schemaVersion, schemaVersion)
    }

    func test_json_whenEncoded_shouldCarrySentenceTranscript() throws {
        let entry = makeTranslatedEntry()

        let data = try SessionExporter.json(entries: [entry], metadata: nil, results: [:])
        let document = try decodeDocument(from: data)

        XCTAssertEqual(document.sentences.first?.transcript, japaneseSentence)
    }

    func test_json_whenPendingResultProvided_shouldIncludeTranslation() throws {
        let entry = makeUntranslatedEntry()
        let pending = SentenceTranslation(lang: "en", text: englishTranslation)

        let data = try SessionExporter.json(entries: [entry], metadata: nil, results: [0: pending])
        let document = try decodeDocument(from: data)

        XCTAssertEqual(document.sentences.first?.translations, [pending])
    }
}
