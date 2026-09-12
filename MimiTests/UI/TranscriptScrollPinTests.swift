import CoreGraphics
@testable import Mimi
import Testing

/// Tests the pure tick→decision core of the transcript's manual bottom
/// pin: the chase on short re-anchor landings, direction-decided
/// unpin/repin, the mixed-tick deferral, growth handling under a
/// stationary offset, and the jump-button visibility mapping.
@Suite("Transcript scroll pin")
struct TranscriptScrollPinTests {

    /// A 1000pt-tall content in a 400pt viewport: flush-bottom offset is
    /// 600, flush-top is 0.
    private func snapshot(
        offsetY: CGFloat = 0,
        contentHeight: CGFloat = 1000,
        containerHeight: CGFloat = 400,
        insetTop: CGFloat = 0,
        insetBottom: CGFloat = 0
    ) -> TranscriptScrollPin.Snapshot {
        TranscriptScrollPin.Snapshot(
            offsetY: offsetY,
            contentHeight: contentHeight,
            containerHeight: containerHeight,
            insetTop: insetTop,
            insetBottom: insetBottom
        )
    }

    // MARK: - Chase while pinned

    @Test("a short re-anchor landing keeps chasing while pinned")
    func shortLandingChases() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 590), new: snapshot(offsetY: 596), pinned: true
        )

        #expect(tick.reanchors)
        #expect(tick.pinnedAfter)
    }

    @Test("a flush landing stops the chase")
    func flushLandingStops() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 590), new: snapshot(offsetY: 600), pinned: true
        )

        #expect(!tick.reanchors)
        #expect(tick.pinnedAfter)
    }

    // MARK: - Unpin / repin

    @Test("dragging up beyond the tolerance drops the pin on a still span")
    func dragUpDropsPin() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 600), new: snapshot(offsetY: 550), pinned: true
        )

        #expect(!tick.reanchors)
        #expect(!tick.pinnedAfter)
    }

    @Test("dragging up within the tolerance keeps the pin")
    func dragUpWithinToleranceKeepsPin() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 600), new: snapshot(offsetY: 594), pinned: true
        )

        #expect(!tick.reanchors)
        #expect(tick.pinnedAfter)
    }

    @Test("a mixed up-tick defers the pin decision")
    func mixedUpTickDefers() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 600),
            new: snapshot(offsetY: 550, contentHeight: 1040),
            pinned: true
        )

        #expect(!tick.reanchors)
        #expect(tick.pinnedAfter)
    }

    @Test("scrolling down into the bottom re-engages the pin and chases")
    func scrollDownRepins() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 500), new: snapshot(offsetY: 598), pinned: false
        )

        #expect(tick.reanchors)
        #expect(tick.pinnedAfter)
    }

    @Test("scrolling down short of the bottom while unpinned does nothing")
    func scrollDownShortStaysUnpinned() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 500), new: snapshot(offsetY: 520), pinned: false
        )

        #expect(!tick.reanchors)
        #expect(!tick.pinnedAfter)
    }

    // MARK: - Growth under a stationary offset

    @Test("growth under a stationary offset re-anchors while pinned")
    func growthReanchorsWhilePinned() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 600),
            new: snapshot(offsetY: 600, contentHeight: 1060),
            pinned: true
        )

        #expect(tick.reanchors)
        #expect(tick.pinnedAfter)
    }

    @Test("growth under a stationary offset does nothing while unpinned")
    func growthDoesNothingWhileUnpinned() {
        let tick = TranscriptScrollPin.tick(
            old: snapshot(offsetY: 300),
            new: snapshot(offsetY: 300, contentHeight: 1060),
            pinned: false
        )

        #expect(!tick.reanchors)
        #expect(!tick.pinnedAfter)
    }

    // MARK: - Jump-button visibility

    @Test("the up button hides until the content top leaves the tolerance")
    func upButtonFollowsDistanceToTop() {
        #expect(!TranscriptScrollPin.visibility(pinned: true, snapshot: nil).up)
        #expect(!TranscriptScrollPin.visibility(pinned: true, snapshot: snapshot(offsetY: 8)).up)
        #expect(TranscriptScrollPin.visibility(pinned: true, snapshot: snapshot(offsetY: 9)).up)
    }

    @Test("the down button tracks the pin flag, including before any tick")
    func downButtonTracksPin() {
        #expect(!TranscriptScrollPin.visibility(pinned: true, snapshot: nil).down)
        #expect(TranscriptScrollPin.visibility(pinned: false, snapshot: nil).down)
        #expect(
            TranscriptScrollPin.visibility(pinned: false, snapshot: snapshot(offsetY: 600)).down
        )
    }
}
