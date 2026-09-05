import Foundation
@testable import Mimi
import Testing

/// Tests the SESSION-card stats plumbing on `AppModel`: the character count
/// (Σ transcript text, translations excluded) and the session clock anchors
/// (`onSessionBegin` sets the start + clears the previous end; `stop`
/// freezes the end while the start anchor survives, so duration stops
/// counting; a capture death anchors `captureLostAt` until restart/new
/// session). The mm:ss formatting itself is view logic (`SidebarView`).
@MainActor
@Suite("AppModel session stats")
struct AppModelSessionStatsTests {

    // MARK: - Fixtures

    private func makeSentence(index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
    }

    /// Stubbed launch check — see `AppModelTests.makeSUT`.
    private func makeSUT() async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelStats"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelStats"),
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return model
    }

    // MARK: - Character count

    @Test("the character count sums the transcript text")
    func characterCountSumsTranscriptText() async {
        let model = await makeSUT()

        model.sessionController.onSentence?(makeSentence(index: 0, text: "テスト"))
        model.sessionController.onSentence?(makeSentence(index: 1, text: "こんにちは"))

        #expect(model.sessionCharacterCount == 8)
    }

    @Test("the character count is zero without entries")
    func characterCountWithoutEntriesIsZero() async {
        let model = await makeSUT()

        #expect(model.sessionCharacterCount == 0)
    }

    // MARK: - Session clock

    /// `onSessionBegin` anchors the start and clears the previous session's
    /// end; `stop` freezes the end while the start anchor survives (duration
    /// reads endedAt − startedAt after stop).
    @Test("session begin anchors the clock and clears the previous end")
    func sessionBeginAnchorsClockAndClearsEnd() async {
        let model = await makeSUT()
        model.phase = .running
        model.sessionController.onSessionBegin?()
        model.stop()
        #expect(await pollUntil { model.phase == .idle }, "stop winds down to idle")

        model.sessionController.onSessionBegin?()

        #expect(model.sessionStartedAt != nil)
        #expect(model.sessionEndedAt == nil, "the previous session's end was cleared")
    }

    @Test("stop freezes the session end while the start anchor survives")
    func stopFreezesEndedAt() async throws {
        let model = await makeSUT()
        model.phase = .running
        model.sessionController.onSessionBegin?()
        let startedAt = try #require(model.sessionStartedAt)

        model.stop()
        #expect(await pollUntil { model.phase == .idle }, "stop winds down to idle")

        #expect(model.sessionEndedAt != nil, "the end anchor is set at stop")
        #expect(model.sessionStartedAt == startedAt, "the start anchor is frozen at stop")
    }

    // MARK: - Capture-lost anchor

    /// A mid-session capture death anchors `captureLostAt` so the SESSION
    /// card freezes the duration during the outage (alongside the
    /// `.sourceLost` phase).
    @Test("a capture error anchors captureLostAt without ending the session")
    func captureErrorAnchorsCaptureLostAt() async {
        let model = await makeSUT()
        model.phase = .running
        model.sessionController.onSessionBegin?()

        model.sessionController.onCaptureError?("stream died")

        #expect(model.phase == .sourceLost)
        #expect(model.captureLostAt != nil)
        #expect(model.sessionEndedAt == nil, "the session itself is not torn down")
    }

    /// Restart recovery clears the anchor; duration resumes from the
    /// surviving session clock.
    @Test("a successful restart clears captureLostAt")
    func restartClearsCaptureLostAt() async {
        let model = await makeSUT()
        model.phase = .running
        model.sessionController.onCaptureError?("stream died")
        #expect(model.captureLostAt != nil)

        model.restartCapture()
        #expect(await pollUntil { model.phase == .running }, "the restart recovers")

        #expect(model.captureLostAt == nil)
    }

    @Test("a new session clears the previous captureLostAt")
    func sessionBeginClearsCaptureLostAt() async {
        let model = await makeSUT()
        model.phase = .running
        model.sessionController.onCaptureError?("stream died")
        #expect(model.captureLostAt != nil)

        model.sessionController.onSessionBegin?()

        #expect(model.captureLostAt == nil)
    }
}
