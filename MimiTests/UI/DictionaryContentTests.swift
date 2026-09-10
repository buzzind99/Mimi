@testable import Mimi
import SwiftUI
import Testing

/// Tests the shared dictionary content assembly (`DictionaryContent`) and
/// the cursor-mode card gating: JLPT and pitch mappings follow the probe
/// record, caps and truncation are enforced, and `.dictionary` swaps
/// ENGINES + AUDIO for the DICTIONARY card.
@MainActor
@Suite("Dictionary lookup content assembly")
struct DictionaryContentTests {

    // MARK: - Fixtures

    private func sense(
        pos: String? = "n", glosses: [String] = ["a gloss"], misc: String? = nil
    ) -> JMDictSense {
        JMDictSense(
            pos: pos, glosses: glosses, misc: misc, restrictedKanji: nil, restrictedKana: nil
        )
    }

    private func entry(
        keb: String? = "お土産", reb: String? = "おみやけ", common: Bool = true,
        jlpt: Int? = 5, hatsuon: String? = "おみ'やけ", accPatts: String? = "0",
        zoPatts: String? = "HLLL", senses: [JMDictSense]? = nil
    ) -> JMDictEntry {
        JMDictEntry(
            entSeq: 1, keb: keb, reb: reb, common: common, jlpt: jlpt,
            hatsuon: hatsuon, accPatts: accPatts, zoPatts: zoPatts,
            senses: senses ?? [sense()]
        )
    }

    private func result(_ matched: String) -> LookupResult {
        LookupResult(matched: matched, entries: [entry(keb: matched)])
    }

    // MARK: - Headword, badges, romaji, POS

    @Test("headword prefers the kanji writing and falls back to the reading")
    func headword() {
        #expect(DictionaryContent.headword(of: entry()) == "お土産")
        #expect(DictionaryContent.headword(of: entry(keb: nil)) == "おみやけ")
    }

    @Test("the JLPT badge uses the probe-fixed ≈N mapping and omits when null")
    func jlptBadge() {
        #expect(DictionaryContent.jlptBadge(nil) == nil)
        #expect(DictionaryContent.jlptBadge(5) == "≈N5")
        #expect(DictionaryContent.jlptBadge(3) == "≈N3")
        #expect(DictionaryContent.jlptBadge(1) == "≈N1")
    }

    @Test("romaji converts the kana reading; unmappable or missing readings omit the line")
    func romaji() {
        #expect(DictionaryContent.romaji(for: entry()) == "omiyake")
        #expect(DictionaryContent.romaji(for: entry(reb: nil)) == nil)
        // Kanji cannot convert — a kanji-string reading is not romaji-able.
        #expect(DictionaryContent.romaji(for: entry(reb: "漢字")) == nil)
    }

    @Test("the POS label is the first stored tag")
    func posLabel() {
        #expect(DictionaryContent.posLabel("n,vs") == "n")
        #expect(DictionaryContent.posLabel("n") == "n")
        #expect(DictionaryContent.posLabel(nil) == nil)
        #expect(DictionaryContent.posLabel("") == nil)
    }

    // MARK: - Pitch pill

    @Test("clean hatsuon renders verbatim alongside the verbatim zoPatts")
    func cleanPitch() {
        let pill = DictionaryContent.pitchPill(for: entry(hatsuon: "おみ'やけ", zoPatts: "HLLL"))
        #expect(pill == DictionaryContent.PitchPill(hatsuon: "おみ'やけ", zoPatts: "HLLL"))
    }

    @Test("marked-up hatsuon text is omitted and only zoPatts shows")
    func markedUpHatsuon() {
        for marked in ["<あい'さつ>", "[あい]さつ", "あい･さつ", "あい~さつ"] {
            let pill = DictionaryContent.pitchPill(for: entry(hatsuon: marked, zoPatts: "HLL"))
            #expect(pill == DictionaryContent.PitchPill(hatsuon: nil, zoPatts: "HLL"))
        }
    }

    @Test("a pitch-less entry omits the pill")
    func pitchlessOmitted() {
        #expect(DictionaryContent.pitchPill(for: entry(hatsuon: nil, zoPatts: nil)) == nil)
        #expect(DictionaryContent.pitchPill(for: entry(hatsuon: "", zoPatts: "")) == nil)
    }

    @Test("no accent-type label exists anywhere in v1")
    func noAccentLabel() {
        // accPatts semantics are unvalidated (probe record); the assembly
        // never derives a label from them.
        let pill = DictionaryContent.pitchPill(for: entry(accPatts: "1,1—0"))
        #expect(pill?.hatsuon == "おみ'やけ", "accPatts never leaks into the pill")
    }

    // MARK: - Caps and truncation

    @Test("senses cap at five with a hidden-count footer")
    func senseCap() {
        let senses = (0 ..< 7).map { sense(glosses: ["gloss \($0)"]) }
        let truncated = DictionaryContent.truncatedSenses(senses)
        #expect(truncated.visible.count == 5)
        #expect(truncated.hidden == 2)
    }

    @Test("the card's tighter sense limit is parameterized")
    func cardSenseLimit() {
        let senses = (0 ..< 7).map { _ in sense() }
        let truncated = DictionaryContent.truncatedSenses(senses, limit: 2)
        #expect(truncated.visible.count == 2)
        #expect(truncated.hidden == 5)
    }

    @Test("glosses cap at three per sense")
    func glossCap() {
        let truncated = DictionaryContent.truncatedGlosses(["a", "b", "c", "d", "e"])
        #expect(Array(truncated.visible) == ["a", "b", "c"])
        #expect(truncated.hidden == 2)
    }

    @Test("also pills cap at two")
    func alsoCap() {
        let also = (0 ..< 3).map { result("word\($0)") }
        #expect(Array(DictionaryContent.truncatedAlso(also)).map(\.matched) == ["word0", "word1"])
        #expect(DictionaryContent.truncatedAlso([]).isEmpty)
    }

    // MARK: - Sidebar mode gating

    @Test("dictionary mode shows DICTIONARY + SESSION only; other modes show ENGINES + AUDIO")
    func sidebarGating() {
        #expect(SidebarView.showsCards(for: .dictionary) == .dictionaryMode)

        for mode in [CursorMode.none, .copy] {
            #expect(SidebarView.showsCards(for: mode) == .enginePair)
        }
    }

    // MARK: - Popover anchor exclusivity

    @Test("popoverItem scopes the selection to its owning surface")
    func popoverScoping() {
        let selected = SelectedLookup(
            content: .found(result: result("お土産"), also: [], origin: .tappedSurface),
            source: .transcript(sentenceIndex: 2, tokenIndex: 1),
            entryIndex: 0
        )
        #expect(
            selected.popoverItem(for: .transcript(sentenceIndex: 2, tokenIndex: 1)) == selected
        )
        #expect(
            selected.popoverItem(for: .transcript(sentenceIndex: 2, tokenIndex: 3)) == nil
        )
        #expect(
            selected.popoverItem(for: .transcript(sentenceIndex: 3, tokenIndex: 1)) == nil
        )
        #expect(selected.popoverItem(for: .liveStrip) == nil)
    }

    // MARK: - Pinned content states

    @Test("the joined-match badge names only join leads")
    func joinedBadge() {
        #expect(DictionaryContent.joinedMatchBadge(for: .join) == "JOINED MATCH")
        #expect(DictionaryContent.joinedMatchBadge(for: .tappedSurface) == nil)
        #expect(DictionaryContent.joinedMatchBadge(for: .tappedLemma) == nil)
        #expect(DictionaryContent.joinedMatchBadge(for: .split) == nil)
    }

    @Test("content accessors expose the display result and the fallback pills per state")
    func contentAccessors() {
        let found = LookupContent.found(
            result: result("お"), also: [result("お土産")], origin: .tappedSurface
        )
        #expect(found.displayResult?.matched == "お")
        #expect(found.fallbackResults.map(\.matched) == ["お土産"])

        let notFound = LookupContent.notFound(surface: "雨尾", related: [result("雨")])
        #expect(notFound.displayResult == nil)
        #expect(notFound.fallbackResults.map(\.matched) == ["雨"])
    }

    @Test("the selection identity follows the matched headword and the not-found surface")
    func identityToken() {
        let found = SelectedLookup(
            content: .found(result: result("お"), also: [], origin: .tappedSurface),
            source: .liveStrip,
            entryIndex: 0
        )
        let promoted = SelectedLookup(
            content: .found(result: result("お土産"), also: [], origin: .tappedSurface),
            source: .liveStrip,
            entryIndex: 0
        )
        let notFound = SelectedLookup(
            content: .notFound(surface: "雨尾", related: []),
            source: .liveStrip,
            entryIndex: 0
        )

        #expect(found.id.hasSuffix("-お"))
        #expect(found.id != promoted.id, "a pill promotion swaps the content identity")
        #expect(notFound.id.contains("not-found:雨尾"))
    }
}
