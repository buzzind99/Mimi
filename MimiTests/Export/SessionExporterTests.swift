import Foundation
@testable import Mimi
import Testing

/// Tests the export formats through the public `SessionExporter` API:
/// plain text, SRT (comma ms), VTT (dot ms + header), and the JSON session
/// document (verified by decoding back, plus a raw-key check pinning the
/// v1 snake_case interchange contract).
@Suite("SessionExporter")
struct SessionExporterTests {

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

    private func decodeDocument(from data: Data) throws -> JSONSessionDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(JSONSessionDocument.self, from: data)
    }

    private func makeEntry(start: Double, end: Double, index: Int) -> SessionEntry {
        let sentence = Sentence(
            index: index, startS: start, endS: end, lang: "ja", text: japaneseSentence
        )
        return SessionEntry(sentence: sentence)
    }

    // MARK: - Plain text

    @Test("interleaved output prefixes timestamps on both lines")
    func plainTextInterleavedPrefixesTimestamps() {
        let entry = makeTranslatedEntry()

        let output = SessionExporter.plainText(entries: [entry])

        #expect(
            output == "\(expectedStartStamp)  \(japaneseSentence)\n\(expectedStartStamp)  \(englishTranslation)\n"
        )
    }

    @Test("untranslated output omits translation lines")
    func plainTextUntranslatedOmitsTranslations() {
        let entry = makeUntranslatedEntry()

        let output = SessionExporter.plainText(entries: [entry])

        #expect(output == "\(expectedStartStamp)  \(japaneseSentence)\n")
    }

    // MARK: - SRT

    @Test("SRT cues use comma milliseconds")
    func srtUsesCommaMilliseconds() {
        let entry = makeTranslatedEntry()
        let expectedCue = "1\n\(expectedSrtTiming)\n\(englishTranslation)\n\n"

        let output = SessionExporter.subtitles(entries: [entry], format: .srt)

        #expect(output == expectedCue)
    }

    @Test("SRT skips cues for untranslated entries")
    func srtSkipsUntranslatedCue() {
        let entry = makeUntranslatedEntry()

        let output = SessionExporter.subtitles(entries: [entry], format: .srt)

        #expect(output == "")
    }

    @Test("cue renders multiple translations as separate lines")
    func cueRendersEachTranslationOnItsOwnLine() {
        var entry = makeUntranslatedEntry()
        entry.appendTranslation(SentenceTranslation(lang: "en", text: "First."))
        entry.appendTranslation(SentenceTranslation(lang: "en", text: "Second."))

        let output = SessionExporter.subtitles(entries: [entry], format: .srt)

        #expect(output == "1\n\(expectedSrtTiming)\nFirst.\nSecond.\n\n")
    }

    @Test("VTT keeps only the header for untranslated entries")
    func vttSkipsUntranslatedCue() {
        let entry = makeUntranslatedEntry()

        let output = SessionExporter.subtitles(entries: [entry], format: .vtt)

        #expect(output == expectedVttHeader + "\n\n")
    }

    @Test("subtitle timings roll over milliseconds, minutes and hours")
    func subtitlesRollOverTimeUnits() {
        var entry = makeEntry(start: 3661.9999, end: 3722.5, index: 0)
        entry.appendTranslation(SentenceTranslation(lang: "en", text: englishTranslation))

        let srt = SessionExporter.subtitles(entries: [entry], format: .srt)
        #expect(srt == "1\n01:01:01,999 --> 01:02:02,500\n\(englishTranslation)\n\n")

        let vtt = SessionExporter.subtitles(entries: [entry], format: .vtt)
        #expect(vtt == "\(expectedVttHeader)\n\n1\n01:01:01.999 --> 01:02:02.500\n\(englishTranslation)\n\n")
    }

    @Test("negative timestamps clamp to zero")
    func negativeTimestampClampsToZero() {
        var entry = makeEntry(start: -3.5, end: 0, index: 0)
        entry.appendTranslation(SentenceTranslation(lang: "en", text: englishTranslation))

        let output = SessionExporter.subtitles(entries: [entry], format: .srt)

        #expect(output == "1\n00:00:00,000 --> 00:00:00,000\n\(englishTranslation)\n\n")
    }

    @Test("cue numbers stay contiguous across untranslated entries")
    func cueNumbersStayContiguous() {
        var first = makeEntry(start: sentenceStart, end: sentenceEnd, index: 0)
        first.appendTranslation(SentenceTranslation(lang: "en", text: englishTranslation))
        let untranslated = makeEntry(start: 2, end: 3, index: 1)
        var third = makeEntry(start: 4, end: 5, index: 2)
        third.appendTranslation(SentenceTranslation(lang: "en", text: "Also nice."))

        let output = SessionExporter.subtitles(
            entries: [first, untranslated, third], format: .srt
        )

        #expect(output.contains("1\n00:00:00,000 --> 00:00:01,500"))
        #expect(!output.contains("\n3\n"))
        #expect(output.contains("2\n00:00:04,000 --> 00:00:05,000"))
    }

    // MARK: - VTT

    @Test("VTT cues use a header and dot milliseconds")
    func vttUsesHeaderAndDotMilliseconds() {
        let entry = makeTranslatedEntry()
        let expectedCue = "\(expectedVttHeader)\n\n1\n\(expectedVttTiming)\n\(englishTranslation)\n\n"

        let output = SessionExporter.subtitles(entries: [entry], format: .vtt)

        #expect(output == expectedCue)
    }

    // MARK: - JSON session

    @Test("JSON output declares the schema version")
    func jsonDeclaresSchemaVersion() throws {
        let entry = makeTranslatedEntry()

        let data = try SessionExporter.json(entries: [entry], metadata: nil, results: [:])
        let document = try decodeDocument(from: data)

        #expect(document.schemaVersion == schemaVersion)
    }

    @Test("JSON output carries the sentence transcript")
    func jsonCarriesTranscript() throws {
        let entry = makeTranslatedEntry()

        let data = try SessionExporter.json(entries: [entry], metadata: nil, results: [:])
        let document = try decodeDocument(from: data)

        #expect(document.sentences.first?.transcript == japaneseSentence)
    }

    @Test("JSON output includes a pending result as a translation")
    func jsonIncludesPendingResult() throws {
        let entry = makeUntranslatedEntry()
        let pending = SentenceTranslation(lang: "en", text: englishTranslation)

        let data = try SessionExporter.json(entries: [entry], metadata: nil, results: [0: pending])
        let document = try decodeDocument(from: data)

        #expect(document.sentences.first?.translations == [pending])
    }

    @Test("entry translations win over pending results")
    func jsonPrefersEntryTranslationOverPendingResult() throws {
        var entry = makeUntranslatedEntry()
        entry.appendTranslation(SentenceTranslation(lang: "en", text: englishTranslation))
        let pending = SentenceTranslation(lang: "en", text: "Stale pending result.")

        let data = try SessionExporter.json(entries: [entry], metadata: nil, results: [0: pending])
        let document = try decodeDocument(from: data)

        #expect(
            document.sentences.first?.translations
                == [SentenceTranslation(lang: "en", text: englishTranslation)]
        )
    }

    @Test("JSON output uses the v1 snake_case keys")
    func jsonEmitsV1SnakeCaseKeys() throws {
        var entry = makeUntranslatedEntry()
        entry.appendTranslation(SentenceTranslation(lang: "en", text: englishTranslation))
        let metadata = SessionMetadata(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceLang: "ja-JP",
            targetLang: "en-US",
            model: "mock",
            chunkMS: 333
        )

        let data = try SessionExporter.json(entries: [entry], metadata: metadata, results: [:])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(object["session"] as? [String: Any])
        let sentences = try #require(object["sentences"] as? [[String: Any]])
        let sentence = try #require(sentences.first)
        let translations = try #require(sentence["translations"] as? [[String: Any]])
        let translation = try #require(translations.first)

        #expect(Set(object.keys) == ["schema_version", "session", "sentences"])
        #expect(object["schema_version"] as? Int == schemaVersion)
        #expect(
            Set(session.keys) == ["started_at", "source_lang", "target_lang", "model", "chunk_ms"]
        )
        #expect(
            Set(sentence.keys)
                == ["index", "start_s", "end_s", "lang", "transcript", "translations"]
        )
        #expect(Set(translation.keys) == ["lang", "text"])
    }

    @Test("nil metadata falls back to session defaults")
    func jsonNilMetadataFallsBackToDefaults() throws {
        let before = Date()

        let data = try SessionExporter.json(entries: [], metadata: nil, results: [:])
        let document = try decodeDocument(from: data)

        #expect(document.session.sourceLang == "ja")
        #expect(document.session.targetLang == "en")
        #expect(document.session.model == nil)
        #expect(document.session.chunkMS == 160)
        // `.iso8601` encoding truncates sub-second precision: the decoded
        // fallback can land up to 1 s before `before`.
        #expect(document.session.startedAt >= before.addingTimeInterval(-1))
        #expect(document.session.startedAt <= Date())
    }

    @Test("partially populated metadata merges with fallbacks")
    func jsonPartialMetadataMergesWithFallbacks() throws {
        let metadata = SessionMetadata(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceLang: nil,
            targetLang: nil,
            model: "test-model",
            chunkMS: 250
        )

        let data = try SessionExporter.json(entries: [], metadata: metadata, results: [:])
        let document = try decodeDocument(from: data)

        #expect(
            abs(document.session.startedAt.timeIntervalSince1970
                - metadata.startedAt.timeIntervalSince1970) < 1
        )
        #expect(document.session.sourceLang == "ja", "nil sourceLang should fall back")
        #expect(document.session.targetLang == "en", "nil targetLang should fall back")
        #expect(document.session.model == "test-model")
        #expect(document.session.chunkMS == 250)
    }

    @Test("fully populated metadata carries all values")
    func jsonFullMetadataCarriesAllValues() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = SessionMetadata(
            startedAt: startedAt,
            sourceLang: "ja-JP",
            targetLang: "en-US",
            model: "mock",
            chunkMS: 333
        )

        let data = try SessionExporter.json(entries: [], metadata: metadata, results: [:])
        let document = try decodeDocument(from: data)

        #expect(
            abs(document.session.startedAt.timeIntervalSince1970
                - startedAt.timeIntervalSince1970) < 1
        )
        #expect(document.session.sourceLang == "ja-JP")
        #expect(document.session.targetLang == "en-US")
        #expect(document.session.model == "mock")
        #expect(document.session.chunkMS == 333)
    }

    // MARK: - Format metadata

    @Test("format file extensions match their case")
    func formatFileExtensions() {
        #expect(SessionExporter.Format.txt.fileExtension == "txt")
        #expect(SessionExporter.Format.srt.fileExtension == "srt")
        #expect(SessionExporter.Format.vtt.fileExtension == "vtt")
        #expect(SessionExporter.Format.json.fileExtension == "json")
    }

    @Test("every format's id equals its display name", arguments: zip(
        SessionExporter.Format.allCases,
        ["Plain text", "SubRip (.srt)", "WebVTT (.vtt)", "JSON session"]
    ))
    func formatIDMatchesDisplayName(format: SessionExporter.Format, expectedID: String) {
        #expect(format.id == expectedID)
    }

    @Test("only the JSON format maps to the JSON content type")
    func formatContentTypeMapsOnlyJSONToJSON() {
        #expect(SessionExporter.Format.json.contentType == .json)
        #expect(SessionExporter.Format.txt.contentType == .plainText)
        #expect(SessionExporter.Format.srt.contentType == .plainText)
        #expect(SessionExporter.Format.vtt.contentType == .plainText)
    }
}
