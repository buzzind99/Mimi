import Foundation
@testable import Mimi
import Testing

/// Tests the dictionary lookup UI state on `AppModel`: a hit selects and
/// pins, the miss posts the warning pill while state persists, empty
/// annotator segments and infrastructure errors post the toast instead
/// (never the pill), the popover anchor is exclusive to its surface,
/// "also:" pills fully re-select, the entry pager pages popover and card
/// together, and session clear resets everything. Lookups run over the
/// committed JMDict fixture database; the async core (`runLookup`) is
/// awaited directly with injected segments. One end-to-end tap test runs
/// the real annotator and is gated on a prepared tokenizer.
@MainActor
@Suite("AppModel dictionary lookup")
final class AppModelLookupTests {

    private let fixture: JMDictFixtureDatabase.Built

    init() throws {
        fixture = try JMDictFixtureDatabase.build()
    }

    deinit {
        fixture.remove()
    }

    // MARK: - Fixtures

    private func makeModel(jmDictLookup: JMDictLookup? = nil) -> AppModel {
        AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelLookup"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelLookup"),
            jmDictLookup: jmDictLookup ?? JMDictLookup(resolveDatabase: { [fixture] in fixture.url }),
            initialModelResolve: { _ in nil }
        )
    }

    /// お in お土産: the tapped surface お leads, then the forward joins
    /// お土産 and the lemma 土産 — all three hit in the fixture.
    private func lookupO() -> [LookupSegment] {
        [LookupSegment(surface: "お"), LookupSegment(surface: "土産", lemma: "土産")]
    }

    private func runHit(_ model: AppModel, source: SelectedLookup.Source) async {
        await model.runLookup(
            segments: lookupO(), tappedAt: 0, sentenceText: "お土産",
            surface: "お", source: source
        )
    }

    // MARK: - Tap entry point

    @Test(
        "handleLookupTap resolves segments at tap time and lands the miss pill",
        .enabled(if: DictionaryStore.resolve() != nil)
    )
    func handleLookupTapLandsOutcome() async {
        let model = makeModel()

        // "xyz" misses the fixture whichever way the real annotator
        // resolves it — a plain run or token-derived segments — so the tap
        // deterministically ends at the warning pill. Gated on a prepared
        // tokenizer: without one the segments come back empty and the tap
        // surfaces the annotator-unavailable error instead.
        model.handleLookupTap(
            LookupToken(
                surface: "xyz", reading: nil, lemma: nil,
                tokenIndex: 0, sentenceText: "xyz"
            ),
            source: .transcript(sentenceIndex: 0, tokenIndex: 0)
        )

        // The tap's Task runs the lookup off-main; poll until it lands —
        // the wait ends as soon as the pill is observable.
        #expect(
            await pollUntil(timeout: 5) { model.notices.message != nil },
            "the tap lands the miss pill"
        )
        #expect(model.notices.message == "No dictionary entry for \"xyz\"")
        #expect(model.notices.tone == .warning)
        #expect(model.selectedLookup == nil)
    }

    @Test("lookup identity distinguishes sources and travels with the matched headword")
    func lookupIdentity() async throws {
        let model = makeModel()

        await runHit(model, source: .transcript(sentenceIndex: 0, tokenIndex: 0))
        let transcriptID = try #require(model.selectedLookup?.id)
        #expect(transcriptID.hasSuffix("-お"))

        await model.runLookup(
            segments: lookupO(), tappedAt: 0, sentenceText: "お土産",
            surface: "お", source: .liveStrip
        )
        let stripID = try #require(model.selectedLookup?.id)
        #expect(transcriptID != stripID)
    }

    // MARK: - Hit: select + pin

    @Test("a hit selects the popover and pins the card with the retained expansion hits")
    func hitSelectsAndPins() async {
        let model = makeModel()

        await runHit(model, source: .liveStrip)

        let selected = model.selectedLookup
        #expect(selected?.source == .liveStrip)
        #expect(selected?.result.matched == "お")
        #expect(selected?.entryIndex == 0)

        let pinned = model.pinnedLookup
        #expect(pinned?.result.matched == "お")
        #expect(pinned?.entryIndex == 0)
        // The tapped surface お displays; the join お土産 hits new entries
        // and is retained as the "also:" hit (the 土産 lemma candidate only
        // re-hits the compound's entries, so it is skipped).
        #expect(pinned?.also.map(\.matched) == ["お土産"])
    }

    // MARK: - Miss: warning pill, state persists

    @Test("a miss posts the warning pill with the tapped surface and leaves state untouched")
    func missPostsWarningPill() async {
        let model = makeModel()
        await runHit(model, source: .liveStrip)
        let pinnedBefore = model.pinnedLookup

        await model.runLookup(
            segments: [LookupSegment(surface: "無語")], tappedAt: 0,
            sentenceText: "無語", surface: "無語", source: .liveStrip
        )

        #expect(model.selectedLookup?.result.matched == "お", "the popover stays up")
        #expect(model.pinnedLookup == pinnedBefore)
        #expect(model.notices.message == "No dictionary entry for \"無語\"")
        #expect(model.notices.tone == .warning)
    }

    // MARK: - Error: toast, no pill

    @Test("an infrastructure error posts the dictionaryLookup toast and never the pill")
    func errorPostsToast() async {
        let engine = JMDictLookup(resolveDatabase: { self.fixture.url })
        engine.close()
        let model = makeModel(jmDictLookup: engine)

        await model.runLookup(
            segments: lookupO(), tappedAt: 0, sentenceText: "お土産",
            surface: "お", source: .liveStrip
        )

        #expect(model.toasts.toasts.first?.key == ToastKey.dictionaryLookup)
        #expect(model.toasts.toasts.first?.style == .yellowAuto)
        #expect(model.selectedLookup == nil, "no popover on error")
        #expect(model.pinnedLookup == nil, "pinned unchanged")
        #expect(model.notices.message == nil, "the pill is reserved for no-hit")
    }

    @Test("empty annotator segments post the error toast and never the no-hit pill")
    func emptySegmentsToast() async {
        let model = makeModel()

        // Empty segments are the annotator refusing to run (its tokenizer
        // dictionary missing) — an error path, not a genuine no-hit.
        await model.runLookup(
            segments: [], tappedAt: 0, sentenceText: "お土産",
            surface: "お", source: .liveStrip
        )

        #expect(model.toasts.toasts.first?.key == ToastKey.dictionaryLookup)
        #expect(model.toasts.toasts.first?.style == .yellowAuto)
        #expect(model.selectedLookup == nil, "no popover on error")
        #expect(model.pinnedLookup == nil, "pinned unchanged")
        #expect(model.notices.message == nil, "the pill is reserved for no-hit")
    }

    // MARK: - Popover anchor exclusivity

    @Test("only the surface whose anchor matches presents the popover")
    func popoverAnchorExclusivity() async {
        let model = makeModel()

        await runHit(model, source: .transcript(sentenceIndex: 3, tokenIndex: 1))

        let selected = model.selectedLookup
        #expect(
            selected?.popoverItem(for: .transcript(sentenceIndex: 3, tokenIndex: 1)) == selected
        )
        // A different word on the same row is a different anchor…
        #expect(
            selected?.popoverItem(for: .transcript(sentenceIndex: 3, tokenIndex: 2)) == nil
        )
        // …as is the same word on a different row, and the strip.
        #expect(
            selected?.popoverItem(for: .transcript(sentenceIndex: 4, tokenIndex: 1)) == nil
        )
        #expect(selected?.popoverItem(for: .liveStrip) == nil)
    }

    @Test("a second tap moves the selection to the new surface")
    func secondTapMovesPopover() async {
        let model = makeModel()

        await runHit(model, source: .transcript(sentenceIndex: 1, tokenIndex: 0))
        await model.runLookup(
            segments: lookupO(), tappedAt: 0, sentenceText: "お土産",
            surface: "お", source: .liveStrip
        )

        #expect(model.selectedLookup?.source == .liveStrip)
    }

    @Test("a second tap on the same word swaps the content while the anchor stays")
    func secondTapSameWordSwapsContent() async {
        let model = makeModel()

        await runHit(model, source: .transcript(sentenceIndex: 1, tokenIndex: 2))
        await model.runLookup(
            segments: [LookupSegment(surface: "あめ")], tappedAt: 0,
            sentenceText: "あめ", surface: "あめ",
            source: .transcript(sentenceIndex: 1, tokenIndex: 2)
        )

        #expect(model.selectedLookup?.source == .transcript(sentenceIndex: 1, tokenIndex: 2))
        #expect(model.selectedLookup?.result.matched == "あめ")
    }

    @Test("a second tap on a different word of the same row moves the anchor")
    func secondTapSameRowDifferentWordMovesAnchor() async {
        let model = makeModel()

        await runHit(model, source: .transcript(sentenceIndex: 1, tokenIndex: 2))
        await model.runLookup(
            segments: [LookupSegment(surface: "あめ")], tappedAt: 0,
            sentenceText: "あめ", surface: "あめ",
            source: .transcript(sentenceIndex: 1, tokenIndex: 5)
        )

        #expect(model.selectedLookup?.source == .transcript(sentenceIndex: 1, tokenIndex: 5))
        #expect(model.selectedLookup?.result.matched == "あめ")
    }

    @Test("dismissal clears the selection only when the dismissing surface owns it; pinned persists")
    func dismissClearsSelectionOnly() async {
        let model = makeModel()
        await runHit(model, source: .liveStrip)
        let pinnedBefore = model.pinnedLookup

        // A stale transcript-row binding (virtualized-off anchor) cannot
        // clobber the live strip's selection…
        model.dismissLookupPopover(source: .transcript(sentenceIndex: 7, tokenIndex: 0))
        #expect(model.selectedLookup != nil)

        // …the strip's own dismiss clears it, and the pinned card stays.
        model.dismissLookupPopover(source: .liveStrip)
        #expect(model.selectedLookup == nil)
        #expect(model.pinnedLookup == pinnedBefore)
    }

    // MARK: - "also:" pills

    @Test("an also-pill tap fully re-selects: popover and pinned update, the row recomputes")
    func alsoPillReselects() async throws {
        let model = makeModel()
        await runHit(model, source: .liveStrip)

        let expansion = try #require(model.pinnedLookup?.also[0])
        model.selectAlsoPill(expansion)

        #expect(model.selectedLookup?.result.matched == "お土産")
        #expect(model.selectedLookup?.source == .liveStrip, "the anchor follows the re-select")
        #expect(model.selectedLookup?.entryIndex == 0)

        // The pill row recomputes from the results relative to お土産: the
        // previous selection (お) becomes its "also:".
        let pinned = try #require(model.pinnedLookup)
        #expect(pinned.result.matched == "お土産")
        #expect(pinned.also.map(\.matched) == ["お"])
    }

    // MARK: - Entry pager

    @Test("the pager pages popover and pinned card together, clamped to the entry count")
    func pagerPagesBoth() async throws {
        let model = makeModel()
        // あめ matches two fixture entries (雨 candy + 雨 rain homograph).
        await model.runLookup(
            segments: [LookupSegment(surface: "あめ")], tappedAt: 0,
            sentenceText: "あめ", surface: "あめ",
            source: .transcript(sentenceIndex: 0, tokenIndex: 0)
        )

        let count = try #require(model.selectedLookup?.result.entries.count)
        #expect(count == 2)

        model.stepLookupEntry(to: 1)
        #expect(model.selectedLookup?.entryIndex == 1)
        #expect(model.pinnedLookup?.entryIndex == 1)

        model.stepLookupEntry(to: 99)
        #expect(model.selectedLookup?.entryIndex == 1, "clamped to the last entry")
        model.stepLookupEntry(to: -5)
        #expect(model.selectedLookup?.entryIndex == 0, "clamped to the first entry")
    }

    // MARK: - Lifecycle

    @Test("session clear resets the popover, the pinned card, and in-flight lookups")
    func sessionClearResets() async {
        let model = makeModel()
        await runHit(model, source: .liveStrip)

        model.sessionController.onSessionBegin?()

        #expect(model.selectedLookup == nil)
        #expect(model.pinnedLookup == nil)

        // A lookup spawned before the clear (stale generation) must not
        // resurrect state afterwards.
        await model.runLookup(
            segments: lookupO(), tappedAt: 0, sentenceText: "お土産",
            surface: "お", source: .liveStrip, generation: -999
        )
        #expect(model.selectedLookup == nil)
        #expect(model.pinnedLookup == nil)
    }
}
