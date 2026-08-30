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

    // MARK: - SessionClock.timestamp

    func test_timestamp_whenUnderOneHour_shouldFormatAsMinutesAndSeconds() {
        let timestamp = SessionClock.timestamp(underHourSeconds)

        XCTAssertEqual(timestamp, expectedUnderHourTimestamp)
    }

    func test_timestamp_whenOverOneHour_shouldFormatAsHoursMinutesAndSeconds() {
        let timestamp = SessionClock.timestamp(overHourSeconds)

        XCTAssertEqual(timestamp, expectedOverHourTimestamp)
    }

    func test_timestamp_whenNegative_shouldClampToZero() {
        let timestamp = SessionClock.timestamp(negativeSeconds)

        XCTAssertEqual(timestamp, expectedClampedTimestamp)
    }

    // MARK: - SessionEntry

    func test_appendTranslation_whenCalledTwice_shouldJoinWithSlash() {
        var entry = makeEntry()

        entry.appendTranslation(SentenceTranslation(lang: "en", text: firstTranslationText))
        entry.appendTranslation(SentenceTranslation(lang: "en", text: secondTranslationText))

        XCTAssertEqual(entry.joinedTranslations, "\(firstTranslationText) / \(secondTranslationText)")
    }
}
