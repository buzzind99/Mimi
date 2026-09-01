@testable import Mimi
import Testing

/// Tests `SessionClock` formatting/conversion and `SessionEntry`'s
/// precomputed display strings.
@Suite("Session models")
struct SessionModelsTests {

    // MARK: - Fixtures

    private let sampleRateSamples = 16000
    private let underHourSeconds = 83.0
    private let expectedUnderHourTimestamp = "01:23"
    private let overHourSeconds = 3661.0
    private let expectedOverHourTimestamp = "01:01:01"
    private let negativeSeconds = -5.0
    private let expectedClampedTimestamp = "00:00"
    private let firstTranslationText = "Hello"
    private let secondTranslationText = "Hi"

    // MARK: - Helpers

    private func makeEntry() -> SessionEntry {
        let sentence = Sentence(index: 0, startS: 0, endS: 1, lang: "ja", text: "テスト")
        return SessionEntry(sentence: sentence)
    }

    // MARK: - SessionClock.seconds

    @Test("converts a sample count at the session rate to seconds")
    func sampleCountToSeconds() {
        let seconds = SessionClock.seconds(sampleRateSamples)

        #expect(seconds == 1.0)
    }

    @Test("zero samples is zero seconds")
    func zeroSamplesIsZero() {
        let seconds = SessionClock.seconds(0)

        #expect(seconds == 0.0)
    }

    @Test("half a second of samples converts to half a second")
    func halfSecondOfSamples() {
        let seconds = SessionClock.seconds(sampleRateSamples / 2)

        #expect(seconds == 0.5)
    }

    // MARK: - SessionClock.timestamp

    @Test("formats under an hour as minutes and seconds")
    func underHourTimestamp() {
        let timestamp = SessionClock.timestamp(underHourSeconds)

        #expect(timestamp == expectedUnderHourTimestamp)
    }

    @Test("formats over an hour as hours, minutes and seconds")
    func overHourTimestamp() {
        let timestamp = SessionClock.timestamp(overHourSeconds)

        #expect(timestamp == expectedOverHourTimestamp)
    }

    @Test("formats exactly one hour as hours, minutes and seconds")
    func exactlyOneHourTimestamp() {
        let timestamp = SessionClock.timestamp(3600)

        #expect(timestamp == "01:00:00")
    }

    @Test("formats just under an hour as minutes and seconds")
    func justUnderHourTimestamp() {
        let timestamp = SessionClock.timestamp(3599.9)

        #expect(timestamp == "59:59")
    }

    @Test("rounds sub-second remainders down")
    func subSecondTimestampRoundsDown() {
        let timestamp = SessionClock.timestamp(underHourSeconds + 0.9)

        #expect(timestamp == expectedUnderHourTimestamp)
    }

    @Test("clamps negative seconds to zero")
    func negativeTimestampClampsToZero() {
        let timestamp = SessionClock.timestamp(negativeSeconds)

        #expect(timestamp == expectedClampedTimestamp)
    }

    // MARK: - Sentence

    @Test("a sentence's id mirrors its index")
    func sentenceIDMirrorsIndex() {
        let sentence = Sentence(index: 7, startS: 0, endS: 1, lang: "ja", text: "テスト")

        #expect(sentence.id == 7)
    }

    // MARK: - SessionEntry

    @Test("an untranslated entry has no joined translations")
    func untranslatedEntryHasNoTranslations() {
        let entry = makeEntry()

        #expect(entry.translations.isEmpty)
        #expect(entry.joinedTranslations == nil)
    }

    @Test("an entry precomputes its timestamps from the sentence")
    func entryPrecomputesTimestamps() {
        let sentence = Sentence(index: 3, startS: 0, endS: 61, lang: "ja", text: "テスト")

        let entry = SessionEntry(sentence: sentence)

        #expect(entry.startTimestamp == "00:00")
        #expect(entry.endTimestamp == "01:01")
    }

    @Test("an entry's id mirrors the sentence index")
    func entryIDMirrorsSentenceIndex() {
        let entry = makeEntry()

        #expect(entry.id == 0)
    }

    @Test("a single translation joins without a separator")
    func singleTranslationJoinsWithoutSeparator() {
        var entry = makeEntry()

        entry.appendTranslation(SentenceTranslation(lang: "en", text: firstTranslationText))

        #expect(entry.joinedTranslations == firstTranslationText)
        #expect(entry.translations == [
            SentenceTranslation(lang: "en", text: firstTranslationText)
        ])
    }

    @Test("two translations join with a slash")
    func twoTranslationsJoinWithSlash() {
        var entry = makeEntry()

        entry.appendTranslation(SentenceTranslation(lang: "en", text: firstTranslationText))
        entry.appendTranslation(SentenceTranslation(lang: "en", text: secondTranslationText))

        #expect(entry.joinedTranslations == "\(firstTranslationText) / \(secondTranslationText)")
    }
}
