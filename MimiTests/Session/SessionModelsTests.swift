@testable import Mimi
import XCTest

/// Tests `SessionClock` formatting/conversion and `SessionEntry`'s
/// precomputed display strings.
final class SessionModelsTests: XCTestCase {

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

    func test_seconds_whenGivenSampleCount_shouldConvertToSeconds() {
        let seconds = SessionClock.seconds(sampleRateSamples)

        XCTAssertEqual(seconds, 1.0)
    }

    func test_seconds_whenZeroSamples_shouldBeZero() {
        let seconds = SessionClock.seconds(0)

        XCTAssertEqual(seconds, 0.0)
    }

    func test_seconds_whenHalfASecondOfSamples_shouldConvertToSeconds() {
        let seconds = SessionClock.seconds(sampleRateSamples / 2)

        XCTAssertEqual(seconds, 0.5)
    }

    // MARK: - SessionClock.timestamp

    func test_timestamp_whenUnderOneHour_shouldFormatAsMinutesAndSeconds() {
        let timestamp = SessionClock.timestamp(underHourSeconds)

        XCTAssertEqual(timestamp, expectedUnderHourTimestamp)
    }

    func test_timestamp_whenOverOneHour_shouldFormatAsHoursMinutesAndSeconds() {
        let timestamp = SessionClock.timestamp(overHourSeconds)

        XCTAssertEqual(timestamp, expectedOverHourTimestamp)
    }

    func test_timestamp_whenExactlyOneHour_shouldFormatAsHoursMinutesAndSeconds() {
        let timestamp = SessionClock.timestamp(3600)

        XCTAssertEqual(timestamp, "01:00:00")
    }

    func test_timestamp_whenJustUnderOneHour_shouldFormatAsMinutesAndSeconds() {
        let timestamp = SessionClock.timestamp(3599.9)

        XCTAssertEqual(timestamp, "59:59")
    }

    func test_timestamp_whenSubSecond_shouldRoundDown() {
        let timestamp = SessionClock.timestamp(underHourSeconds + 0.9)

        XCTAssertEqual(timestamp, expectedUnderHourTimestamp)
    }

    func test_timestamp_whenNegative_shouldClampToZero() {
        let timestamp = SessionClock.timestamp(negativeSeconds)

        XCTAssertEqual(timestamp, expectedClampedTimestamp)
    }

    // MARK: - Sentence

    func test_sentence_id_shouldMirrorIndex() {
        let sentence = Sentence(index: 7, startS: 0, endS: 1, lang: "ja", text: "テスト")

        XCTAssertEqual(sentence.id, 7)
    }

    // MARK: - SessionEntry

    func test_init_whenUntranslated_shouldLeaveJoinedTranslationsNil() {
        let entry = makeEntry()

        XCTAssertTrue(entry.translations.isEmpty)
        XCTAssertNil(entry.joinedTranslations)
    }

    func test_init_shouldPrecomputeTimestampsFromSentence() {
        let sentence = Sentence(index: 3, startS: 0, endS: 61, lang: "ja", text: "テスト")

        let entry = SessionEntry(sentence: sentence)

        XCTAssertEqual(entry.startTimestamp, "00:00")
        XCTAssertEqual(entry.endTimestamp, "01:01")
    }

    func test_id_shouldMirrorSentenceIndex() {
        let entry = makeEntry()

        XCTAssertEqual(entry.id, 0)
    }

    func test_appendTranslation_whenCalledOnce_shouldJoinWithoutSeparator() {
        var entry = makeEntry()

        entry.appendTranslation(SentenceTranslation(lang: "en", text: firstTranslationText))

        XCTAssertEqual(entry.joinedTranslations, firstTranslationText)
        XCTAssertEqual(entry.translations, [
            SentenceTranslation(lang: "en", text: firstTranslationText)
        ])
    }

    func test_appendTranslation_whenCalledTwice_shouldJoinWithSlash() {
        var entry = makeEntry()

        entry.appendTranslation(SentenceTranslation(lang: "en", text: firstTranslationText))
        entry.appendTranslation(SentenceTranslation(lang: "en", text: secondTranslationText))

        XCTAssertEqual(entry.joinedTranslations, "\(firstTranslationText) / \(secondTranslationText)")
    }
}
