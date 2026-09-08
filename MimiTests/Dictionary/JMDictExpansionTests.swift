import Foundation
@testable import Mimi
import Testing

/// The pure forward-expansion candidate builder: join rules, adjacency
/// validation against the sentence text, caps, and candidate ordering.
@Suite("JMDictExpansion candidates")
final class JMDictExpansionCandidateTests {
    private func segments(_ pairs: (surface: String, lemma: String?)...) -> [LookupSegment] {
        pairs.map { LookupSegment(surface: $0.surface, lemma: $0.lemma) }
    }

    @Test("joins forward segments longest-first around the tap")
    func compoundJoin() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), ("土産", "土産")),
            tappedAt: 0,
            sentenceText: "お土産"
        )

        #expect(candidates.map(\.text) == ["お土産", "お"])
    }

    @Test("a tap mid-sentence expands forward only")
    func forwardOnly() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), ("土産", "土産")),
            tappedAt: 1,
            sentenceText: "お土産"
        )

        #expect(candidates.map(\.text) == ["土産"])
    }

    @Test("prefers the lemma over the surface for the single-token candidate")
    func lemmaFirstPreference() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("食べ", "食べる"), ("ま", nil), ("した", nil)),
            tappedAt: 0,
            sentenceText: "食べました"
        )

        // The joins miss first; the truncated surface candidate would only
        // re-hit the lemma's entries — the cap keeps the queries at three.
        #expect(candidates.map(\.text) == ["食べました", "食べま", "食べる"])
    }

    @Test("never queries more than the candidate cap")
    func candidateCap() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("あ", nil), ("い", nil), ("う", nil), ("え", nil)),
            tappedAt: 0,
            sentenceText: "あいうえ"
        )

        #expect(candidates.count <= JMDictExpansion.maxCandidates)
        #expect(candidates.map(\.text) == ["あいう", "あい", "あ"])
    }

    @Test("skips whitespace-only segments and still joins across them")
    func whitespaceGapJoins() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), (" ", nil), ("土産", "土産")),
            tappedAt: 0,
            sentenceText: "お 土産"
        )

        #expect(candidates.map(\.text) == ["お土産", "お"])
    }

    @Test("a non-whitespace gap in the sentence text stops expansion")
    func punctuationGapStopsExpansion() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), ("土産", "土産")),
            tappedAt: 0,
            sentenceText: "お、土産"
        )

        #expect(candidates.map(\.text) == ["お"])
    }

    @Test("a punctuation-only segment stops expansion")
    func punctuationSegmentStopsExpansion() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("本", nil), ("、", nil), ("読む", "読む")),
            tappedAt: 0,
            sentenceText: "本、読む"
        )

        #expect(candidates.map(\.text) == ["本"])
    }

    @Test("a numeral-run segment stops expansion")
    func numeralRunStopsExpansion() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("本", nil), ("3", nil), ("冊", nil)),
            tappedAt: 0,
            sentenceText: "本 3冊"
        )

        #expect(candidates.map(\.text) == ["本"])
    }

    @Test("an overridden-particle segment stops expansion")
    func particleStopsExpansion() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("で", nil), ("は", "は")),
            tappedAt: 0,
            sentenceText: "では"
        )

        #expect(candidates.map(\.text) == ["で"])
    }

    @Test("does not duplicate the single candidate when the lemma equals the surface")
    func lemmaSurfaceDeduplicated() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("土産", "土産")),
            tappedAt: 0,
            sentenceText: "土産"
        )

        #expect(candidates.map(\.text) == ["土産"])
    }

    @Test("an out-of-bounds tap index yields no candidates")
    func outOfBoundsIndex() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("あ", nil)),
            tappedAt: 5,
            sentenceText: "あ"
        )

        #expect(candidates.isEmpty)
    }

    @Test("a sentence text that has drifted away from the segments fails closed")
    func driftedSentenceTextFailsClosed() {
        // The surfaces no longer sit where the sentence text has them: no
        // join candidate is produced, the tapped segment still queries.
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), ("土産", "土産")),
            tappedAt: 0,
            sentenceText: "違う文です"
        )

        #expect(candidates.map(\.text) == ["お"])
    }

    // MARK: Reading threading

    @Test("joins concatenate member readings; the single candidate keeps the tap's")
    func readingThreading() {
        let candidates = JMDictExpansion.candidates(
            segments: [
                LookupSegment(surface: "前", reading: "まえ"),
                LookupSegment(surface: "の", reading: "の")
            ],
            tappedAt: 0,
            sentenceText: "前の"
        )

        #expect(candidates.map(\.text) == ["前の", "前"])
        #expect(candidates.map(\.reading) == ["まえの", "まえ"])
    }

    @Test("a join member without a reading drops the joined reading")
    func joinedReadingDroppedWhenPartial() {
        let candidates = JMDictExpansion.candidates(
            segments: [
                LookupSegment(surface: "前", reading: "まえ"),
                LookupSegment(surface: "の")
            ],
            tappedAt: 0,
            sentenceText: "前の"
        )

        #expect(candidates.map(\.text) == ["前の", "前"])
        #expect(candidates[0].reading == nil)
        #expect(candidates[1].reading == "まえ")
    }

    @Test("a lemma candidate carries the tapped segment's reading")
    func lemmaCandidateCarriesReading() {
        let candidates = JMDictExpansion.candidates(
            segments: [
                LookupSegment(surface: "食べ", lemma: "食べる", reading: "たべ"),
                LookupSegment(surface: "ま", reading: "ま"),
                LookupSegment(surface: "した", reading: "した")
            ],
            tappedAt: 0,
            sentenceText: "食べました"
        )

        #expect(candidates.last?.text == "食べる")
        #expect(candidates.last?.reading == "たべ")
    }
}

/// The engine-level expansion entry point over the fixture database.
@Suite("JMDictLookup forward expansion")
final class JMDictExpansionTests {
    private let databaseURL: URL
    private let engine: JMDictLookup

    init() throws {
        let built = try JMDictFixtureDatabase.build()
        databaseURL = built.url
        engine = JMDictLookup(resolveDatabase: { [url = built.url] in url })
    }

    deinit {
        engine.close()
        JMDictFixtureDatabase.Built(url: databaseURL).remove()
    }

    @Test("displays the longest join: お+土産 resolves お土産")
    func compoundHit() throws {
        let outcome = try #require(try engine.lookup(
            segments: [LookupSegment(surface: "お"), LookupSegment(surface: "土産", lemma: "土産")],
            tappedAt: 0,
            sentenceText: "お土産"
        ))

        #expect(outcome.display.matched == "お土産")
        #expect(outcome.display.entries.map(\.entSeq) == [1_002_500])
    }

    @Test("joins across a whitespace gap the segments carry")
    func whitespaceGapHit() throws {
        let outcome = try #require(try engine.lookup(
            segments: [
                LookupSegment(surface: "お"),
                LookupSegment(surface: " "),
                LookupSegment(surface: "土産", lemma: "土産")
            ],
            tappedAt: 0,
            sentenceText: "お 土産"
        ))

        #expect(outcome.display.matched == "お土産")
    }

    @Test("falls back to the lemma when the joins miss")
    func lemmaFallbackHit() throws {
        let outcome = try #require(try engine.lookup(
            segments: [
                LookupSegment(surface: "食べ", lemma: "食べる"),
                LookupSegment(surface: "ま"),
                LookupSegment(surface: "した")
            ],
            tappedAt: 0,
            sentenceText: "食べました"
        ))

        #expect(outcome.display.matched == "食べる")
        #expect(outcome.display.entries.map(\.entSeq) == [1_358_280])
    }

    @Test("retains shorter hits that add new entries as results")
    func shorterHitsRetained() throws {
        let outcome = try #require(try engine.lookup(
            segments: [LookupSegment(surface: "お"), LookupSegment(surface: "土産", lemma: "土産")],
            tappedAt: 0,
            sentenceText: "お土産"
        ))

        #expect(outcome.also.map(\.matched) == ["お"])
        #expect(outcome.also[0].entries.map(\.entSeq) == [9_990_040])
    }

    @Test("the tap's furigana ranks the matching entry first in the display result")
    func furiganaRanksEntryFirst() throws {
        let outcome = try #require(try engine.lookup(
            segments: [LookupSegment(surface: "前", reading: "まえ")],
            tappedAt: 0,
            sentenceText: "前"
        ))

        #expect(outcome.display.entries.map(\.entSeq) == [9_990_060, 9_990_050])
    }

    @Test("every candidate missing is a miss, not an error")
    func noHitReturnsNil() throws {
        let outcome = try engine.lookup(
            segments: [LookupSegment(surface: "きのこっぷ")],
            tappedAt: 0,
            sentenceText: "きのこっぷ"
        )

        #expect(outcome == nil)
    }

    @Test("an infrastructure error on any query aborts the tap as a throw")
    func infraErrorPropagates() throws {
        _ = try engine.lookup(LookupCandidate(text: "食べる"))
        engine.close()

        let thrown = #expect(throws: JMDictLookupError.self) {
            try engine.lookup(
                segments: [LookupSegment(surface: "食べ", lemma: "食べる"), LookupSegment(surface: "ま")],
                tappedAt: 0,
                sentenceText: "食べま"
            )
        }

        #expect(thrown == .databaseClosed)
    }
}
