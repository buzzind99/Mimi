@testable import Mimi
import Testing

@Suite("HUDHistory")
struct HUDHistoryTests {

    // MARK: - Helpers

    private func entry(_ index: Int) -> SessionEntry {
        SessionEntry(
            sentence: Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: "text\(index)")
        )
    }

    private func entries(_ indexes: Int...) -> [SessionEntry] {
        indexes.map(entry)
    }

    // MARK: - displayedIndex

    @Test("displayedIndex returns nil for empty entries")
    func displayedIndexEmpty() {
        #expect(HUDHistory.displayedIndex(in: [], pinned: nil) == nil)
        #expect(HUDHistory.displayedIndex(in: [], pinned: 7) == nil)
    }

    @Test("displayedIndex returns the newest entry without a pin")
    func displayedIndexNoPin() {
        let entries = entries(0, 1, 2)

        #expect(HUDHistory.displayedIndex(in: entries, pinned: nil) == 2)
    }

    @Test("displayedIndex follows a pin that still resolves")
    func displayedIndexValidPin() {
        let entries = entries(0, 1, 2)

        #expect(HUDHistory.displayedIndex(in: entries, pinned: 0) == 0)
        #expect(HUDHistory.displayedIndex(in: entries, pinned: 2) == 2)
    }

    @Test("displayedIndex falls back to newest for a stale pin")
    func displayedIndexStalePin() {
        let entries = entries(0, 1, 2)

        #expect(HUDHistory.displayedIndex(in: entries, pinned: 99) == 2)
    }

    @Test("displayedIndex handles a single entry with any pin")
    func displayedIndexSingleEntry() {
        let entries = entries(5)

        #expect(HUDHistory.displayedIndex(in: entries, pinned: nil) == 5)
        #expect(HUDHistory.displayedIndex(in: entries, pinned: 5) == 5)
        #expect(HUDHistory.displayedIndex(in: entries, pinned: 3) == 5)
    }

    // MARK: - cycle

    @Test("cycle on empty entries leaves the pin unchanged")
    func cycleEmpty() {
        #expect(HUDHistory.cycle(entries: [], pinned: nil, step: -1) == nil)
        #expect(HUDHistory.cycle(entries: [], pinned: 3, step: 1) == 3)
    }

    @Test("cycle with no pin steps from the newest entry")
    func cycleFromNewestWithoutPin() {
        let entries = entries(0, 1, 2)

        #expect(HUDHistory.cycle(entries: entries, pinned: nil, step: -1) == 1)
    }

    @Test("cycle with no pin stepping newer stays re-following latest")
    func cycleNewerWithoutPin() {
        let entries = entries(0, 1, 2)

        #expect(HUDHistory.cycle(entries: entries, pinned: nil, step: 1) == nil)
    }

    @Test("cycle clears the pin when stepping onto the newest entry")
    func cycleClearsPinAtNewest() {
        let entries = entries(0, 1, 2)

        #expect(HUDHistory.cycle(entries: entries, pinned: 1, step: 1) == nil)
    }

    @Test("cycle clamps at the oldest entry")
    func cycleClampsAtOldest() {
        let entries = entries(0, 1, 2)

        #expect(HUDHistory.cycle(entries: entries, pinned: 0, step: -1) == 0)
    }

    @Test("cycle with a stale pin leaves it unchanged")
    func cycleStalePin() {
        let entries = entries(0, 1, 2)

        #expect(HUDHistory.cycle(entries: entries, pinned: 42, step: -1) == 42)
    }

    @Test("cycle steps through the entries", arguments: [
        // (pinned, step, expected)
        (0, -1, Optional(0)),
        (0, 1, Optional(1)),
        (1, 1, nil),
        (1, -1, Optional(0)),
        (2, -1, Optional(1)),
        (2, 1, Optional(2)),
    ])
    func cycleStepping(pinned: Int?, step: Int, expected: Int?) {
        let entries = entries(0, 1, 2)

        #expect(HUDHistory.cycle(entries: entries, pinned: pinned, step: step) == expected)
    }

    @Test("cycle on a single entry never moves")
    func cycleSingleEntry() {
        let entries = entries(7)

        #expect(HUDHistory.cycle(entries: entries, pinned: nil, step: -1) == nil)
        #expect(HUDHistory.cycle(entries: entries, pinned: 7, step: -1) == 7)
        #expect(HUDHistory.cycle(entries: entries, pinned: 7, step: 1) == 7)
    }

    // MARK: - Enablement

    @Test("enablement on empty entries disables both directions")
    func enablementEmpty() {
        #expect(!HUDHistory.canStepNewer(entries: [], pinned: nil))
        #expect(!HUDHistory.canStepOlder(entries: [], pinned: nil))
    }

    @Test("enablement on a single entry disables both directions")
    func enablementSingle() {
        let entries = entries(0)

        #expect(!HUDHistory.canStepNewer(entries: entries, pinned: nil))
        #expect(!HUDHistory.canStepOlder(entries: entries, pinned: nil))
        #expect(!HUDHistory.canStepNewer(entries: entries, pinned: 0))
        #expect(!HUDHistory.canStepOlder(entries: entries, pinned: 0))
    }

    @Test("enablement with no pin allows older only")
    func enablementNoPin() {
        let entries = entries(0, 1, 2)

        #expect(!HUDHistory.canStepNewer(entries: entries, pinned: nil))
        #expect(HUDHistory.canStepOlder(entries: entries, pinned: nil))
    }

    @Test("enablement per pinned position", arguments: [
        // (pinned, canNewer, canOlder)
        (0, true, false),
        (1, true, true),
        (2, false, true),
    ])
    func enablementAtPin(pinned: Int, canNewer: Bool, canOlder: Bool) {
        let entries = entries(0, 1, 2)

        #expect(HUDHistory.canStepNewer(entries: entries, pinned: pinned) == canNewer)
        #expect(HUDHistory.canStepOlder(entries: entries, pinned: pinned) == canOlder)
    }
}
