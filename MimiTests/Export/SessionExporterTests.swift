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

    private func makeEntry(start: Double, end: Double, index: Int) -> SessionEntry {
        let sentence = Sentence(
            index: index, startS: start, endS: end, lang: "ja", text: japaneseSentence
        )
        return SessionEntry(sentence: sentence)
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

    func test_subtitles_whenVttAndEntryUntranslated_shouldSkipCue() {
        let entry = makeUntranslatedEntry()

        let output = SessionExporter.subtitles(entries: [entry], format: .vtt)

        XCTAssertEqual(output, expectedVttHeader + "\n\n")
    }

    func test_subtitles_whenTimestampsRollOverMillisecondsMinutesAndHours() {
        var entry = makeEntry(start: 3661.9999, end: 3722.5, index: 0)
        entry.appendTranslation(SentenceTranslation(lang: "en", text: englishTranslation))

        let srt = SessionExporter.subtitles(entries: [entry], format: .srt)
        XCTAssertEqual(
            srt, "1\n01:01:01,999 --> 01:02:02,500\n\(englishTranslation)\n\n"
        )

        let vtt = SessionExporter.subtitles(entries: [entry], format: .vtt)
        XCTAssertEqual(
            vtt, "\(expectedVttHeader)\n\n1\n01:01:01.999 --> 01:02:02.500\n\(englishTranslation)\n\n"
        )
    }

    func test_subtitles_whenTimestampNegative_shouldClampToZero() {
        var entry = makeEntry(start: -3.5, end: 0, index: 0)
        entry.appendTranslation(SentenceTranslation(lang: "en", text: englishTranslation))

        let output = SessionExporter.subtitles(entries: [entry], format: .srt)

        XCTAssertEqual(output, "1\n00:00:00,000 --> 00:00:00,000\n\(englishTranslation)\n\n")
    }

    func test_subtitles_whenUntranslatedEntryBetweenTranslatedOnes_shouldKeepCueNumbersContiguous() {
        var first = makeEntry(start: sentenceStart, end: sentenceEnd, index: 0)
        first.appendTranslation(SentenceTranslation(lang: "en", text: englishTranslation))
        let untranslated = makeEntry(start: 2, end: 3, index: 1)
        var third = makeEntry(start: 4, end: 5, index: 2)
        third.appendTranslation(SentenceTranslation(lang: "en", text: "Also nice."))

        let output = SessionExporter.subtitles(
            entries: [first, untranslated, third], format: .srt
        )

        XCTAssertTrue(output.contains("1\n00:00:00,000 --> 00:00:01,500"))
        XCTAssertFalse(output.contains("\n3\n"))
        XCTAssertTrue(output.contains("2\n00:00:04,000 --> 00:00:05,000"))
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

    func test_json_whenMetadataNil_shouldFallBackToDefaults() throws {
        let before = Date()

        let data = try SessionExporter.json(entries: [], metadata: nil, results: [:])
        let document = try decodeDocument(from: data)

        XCTAssertEqual(document.session.sourceLang, "ja")
        XCTAssertEqual(document.session.targetLang, "en")
        XCTAssertNil(document.session.model)
        XCTAssertEqual(document.session.chunkMS, 160)
        XCTAssertNil(document.session.streamOffset)
        XCTAssertGreaterThanOrEqual(document.session.startedAt, before.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(document.session.startedAt, Date().addingTimeInterval(1))
    }

    func test_json_whenMetadataPartiallyPopulated_shouldMergeWithFallbacks() throws {
        let metadata = SessionMetadata(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceLang: nil,
            targetLang: nil,
            model: "test-model",
            chunkMS: 250,
            streamOffset: nil
        )

        let data = try SessionExporter.json(entries: [], metadata: metadata, results: [:])
        let document = try decodeDocument(from: data)

        XCTAssertEqual(
            document.session.startedAt.timeIntervalSince1970,
            metadata.startedAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(document.session.sourceLang, "ja", "nil sourceLang should fall back")
        XCTAssertEqual(document.session.targetLang, "en", "nil targetLang should fall back")
        XCTAssertEqual(document.session.model, "test-model")
        XCTAssertEqual(document.session.chunkMS, 250)
        XCTAssertNil(document.session.streamOffset)
    }

    func test_json_whenMetadataFullyPopulated_shouldCarryAllValues() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = SessionMetadata(
            startedAt: startedAt,
            sourceLang: "ja",
            targetLang: "en",
            model: "mock",
            chunkMS: 160,
            streamOffset: 12.5
        )

        let data = try SessionExporter.json(entries: [], metadata: metadata, results: [:])
        let document = try decodeDocument(from: data)

        XCTAssertEqual(
            document.session.startedAt.timeIntervalSince1970,
            startedAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(document.session.sourceLang, "ja")
        XCTAssertEqual(document.session.targetLang, "en")
        XCTAssertEqual(document.session.model, "mock")
        XCTAssertEqual(document.session.chunkMS, 160)
        XCTAssertEqual(document.session.streamOffset, 12.5)
    }

    // MARK: - Format metadata

    func test_format_fileExtension_shouldMatchCase() {
        XCTAssertEqual(SessionExporter.Format.txt.fileExtension, "txt")
        XCTAssertEqual(SessionExporter.Format.srt.fileExtension, "srt")
        XCTAssertEqual(SessionExporter.Format.vtt.fileExtension, "vtt")
        XCTAssertEqual(SessionExporter.Format.json.fileExtension, "json")
    }

    func test_format_id_shouldEqualRawValue() {
        for format in SessionExporter.Format.allCases {
            XCTAssertEqual(format.id, format.rawValue)
        }
    }
}
