import Foundation
@testable import Mimi
import Testing

/// Tests the notice pill tone state: the default is confirm, a warning post
/// travels with its message, a re-post replaces the tone in place, and
/// dismissal resets to confirm. The tone→token mapping is asserted one
/// test per tone.
@MainActor
@Suite("NoticeCenter tone")
struct NoticeCenterToneTests {

    private func makeSUT() -> NoticeCenter {
        // The tone suites assert state, not timing — the default
        // real-time scheduler is fine (no test fires a timer).
        NoticeCenter()
    }

    // MARK: - Tone state

    @Test("a fresh center posts confirm-toned notices by default")
    func defaultTone() {
        let center = makeSUT()

        #expect(center.tone == .confirm)

        center.post(message: "Text copied")
        #expect(center.tone == .confirm)
    }

    @Test("a warning post sets the tone with the message")
    func warningPost() {
        let center = makeSUT()

        center.post(message: "No dictionary entry for \"無語\"", tone: .warning)

        #expect(center.message == "No dictionary entry for \"無語\"")
        #expect(center.tone == .warning)
    }

    @Test("a re-post replaces the tone in place")
    func repostReplacesTone() {
        let center = makeSUT()

        center.post(message: "No dictionary entry", tone: .warning)
        center.post(message: "Text copied")

        #expect(center.message == "Text copied")
        #expect(center.tone == .confirm)
    }

    @Test("dismiss resets the tone to confirm")
    func dismissResetsTone() {
        let center = makeSUT()

        center.post(message: "No dictionary entry", tone: .warning)
        center.dismiss()

        #expect(center.message == nil)
        #expect(center.tone == .confirm)
    }

    // MARK: - Tone → token mapping

    @Test("confirm maps to the teal notice tokens")
    func confirmTokens() {
        #expect(
            Theme.noticeTokens(for: .confirm)
                == NoticePillTokens(fill: Theme.noticeFill, text: Theme.noticeText)
        )
    }

    @Test("warning maps to the amber notice tokens")
    func warningTokens() {
        #expect(
            Theme.noticeTokens(for: .warning)
                == NoticePillTokens(fill: Theme.noticeWarningFill, text: Theme.noticeWarningText)
        )
    }
}
