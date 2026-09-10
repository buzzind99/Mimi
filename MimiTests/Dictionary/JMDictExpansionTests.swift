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

    @Test("joins forward segments longest-first behind the tapped candidate")
    func compoundJoin() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), ("土産", "土産")),
            tappedAt: 0,
            sentenceText: "お土産"
        )

        #expect(candidates.map(\.text) == ["お", "お土産"])
    }

    @Test("a tap mid-sentence expands forward only")
    func forwardOnly() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), ("土産", "土産")),
            tappedAt: 1,
            sentenceText: "お土産"
        )

        // The kanji splits trail (the 土産 surface itself is deduplicated).
        #expect(candidates.map(\.text) == ["土産", "土", "産"])
    }

    @Test("the surface leads the lemma for the single-token candidates")
    func surfaceFirstPreference() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("食べ", "食べる"), ("ま", nil), ("した", nil)),
            tappedAt: 0,
            sentenceText: "食べました"
        )

        // The tapped surface leads, the lemma follows as the miss fallback,
        // the joins come longest-first, and the kanji split trails them all.
        #expect(candidates.map(\.text) == ["食べ", "食べる", "食べました", "食べま", "食"])
    }

    @Test("a surface that is itself a headword leads its lemma (な tap shows な, not だ)")
    func surfaceLeadsCopulaLemma() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("な", "だ")),
            tappedAt: 0,
            sentenceText: "な"
        )

        #expect(candidates.map(\.text) == ["な", "だ"])
    }

    @Test("never queries more than the candidate cap")
    func candidateCap() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("あ", nil), ("い", nil), ("う", nil), ("え", nil)),
            tappedAt: 0,
            sentenceText: "あいうえ"
        )

        #expect(candidates.count <= JMDictExpansion.maxCandidates)
        #expect(candidates.map(\.text) == ["あ", "あいう", "あい"])
    }

    @Test("skips whitespace-only segments and still joins across them")
    func whitespaceGapJoins() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), (" ", nil), ("土産", "土産")),
            tappedAt: 0,
            sentenceText: "お 土産"
        )

        #expect(candidates.map(\.text) == ["お", "お土産"])
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

        // The split matching the surface is deduplicated; the shorter
        // substrings trail.
        #expect(candidates.map(\.text) == ["土産", "土", "産"])
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

    // MARK: Kanji splits

    @Test("a multi-kanji surface splits into per-kanji candidates behind it")
    func kanjiSplit() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("映画", nil)),
            tappedAt: 0,
            sentenceText: "映画"
        )

        // The longest split (映画) is the surface itself and is deduplicated.
        #expect(candidates.map(\.text) == ["映画", "映", "画"])
    }

    @Test("kana breaks a kanji run: only the runs split, longest substrings first")
    func kanaBreaksRuns() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("食べ物", nil)),
            tappedAt: 0,
            sentenceText: "食べ物"
        )

        #expect(candidates.map(\.text) == ["食べ物", "食", "物"])
    }

    @Test("substring splits honor the split-length cap and the candidate cap")
    func splitLengthCap() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("東京駅前", nil)),
            tappedAt: 0,
            sentenceText: "東京駅前"
        )

        // Length-3 substrings, then 2, then 1 — truncated at the candidate
        // cap before the single-kanji tail completes.
        #expect(candidates.map(\.text) == [
            "東京駅前", "東京駅", "京駅前", "東京", "京駅", "駅前", "東", "京", "駅"
        ])
    }

    @Test("single-kanji and kana-only surfaces emit no split candidates")
    func noSplitsForSingleKanjiAndKana() {
        // A single-kanji surface's only substring is itself (deduplicated).
        #expect(JMDictExpansion.candidates(
            segments: segments(("本", nil)), tappedAt: 0, sentenceText: "本"
        ).map(\.text) == ["本"])
        #expect(JMDictExpansion.candidates(
            segments: segments(("あめ", nil)), tappedAt: 0, sentenceText: "あめ"
        ).map(\.text) == ["あめ"])
    }

    @Test("split candidates carry no reading and derive the kanji kind")
    func splitCandidatesCarryNoReading() {
        let candidates = JMDictExpansion.candidates(
            segments: [LookupSegment(surface: "映画", reading: "えいが")],
            tappedAt: 0,
            sentenceText: "映画"
        )

        let splits = candidates.dropFirst()

        #expect(splits.map(\.text) == ["映", "画"])
        #expect(splits.map(\.reading).allSatisfy { $0 == nil })
        #expect(splits.map(\.kind).allSatisfy { $0 == .kanji })
    }

    @Test("splits trail the joins and never duplicate an earlier candidate")
    func splitsTrailJoinsDeduplicated() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("生徒", "生徒"), ("会", "会")),
            tappedAt: 0,
            sentenceText: "生徒会"
        )

        // The join comes before the splits; the 生徒 split (the surface
        // itself) is deduplicated away and the joined text contributes the
        // boundary-crossing 徒会 (the neighbor's 会 stays one tap away).
        #expect(candidates.map(\.text) == ["生徒", "生徒会", "生", "徒", "徒会"])
    }

    @Test("the joined text's boundary-crossing splits trail the tapped surface's")
    func joinedTextSplitsAfterTappedSplits() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("風呂", nil), ("敷", nil)),
            tappedAt: 0,
            sentenceText: "風呂敷"
        )

        // The tapped surface's splits (風, 呂) lead; the joined text adds
        // only the boundary-crossing 呂敷 — the neighbor's 敷 stays one
        // tap away on the 敷 segment, and the join itself deduplicates.
        #expect(candidates.map(\.text) == ["風呂", "風呂敷", "風", "呂", "呂敷"])
    }

    @Test("a kana tap gains no boundary-crossing splits across a kanji neighbor")
    func kanaTapNoCrossingSplits() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), ("土産", "土産")),
            tappedAt: 0,
            sentenceText: "お土産"
        )

        // The kanji run starts inside the neighbor, so no substring of
        // お土産 straddles the tap boundary: the join alone remains.
        #expect(candidates.map(\.text) == ["お", "お土産"])
    }

    @Test("joined-text splits truncate behind the tapped surface's under the cap")
    func joinedSplitsTruncatedBehindTappedSplits() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("東京駅前", nil), ("駅", nil)),
            tappedAt: 0,
            sentenceText: "東京駅前駅"
        )

        // The join itself occupies a candidate slot (longest-first joins
        // rank above splits), so the tapped surface's eight splits leave
        // one slot and the joined text's boundary-crossing splits fall to
        // the cap before emitting.
        #expect(candidates.map(\.text) == [
            "東京駅前", "東京駅前駅", "東京駅", "京駅前", "東京", "京駅", "駅前", "東", "京"
        ])
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

        #expect(candidates.map(\.text) == ["前", "前の"])
        #expect(candidates.map(\.reading) == ["まえ", "まえの"])
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

        #expect(candidates.map(\.text) == ["前", "前の"])
        #expect(candidates[0].reading == "まえ")
        #expect(candidates[1].reading == nil)
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

        #expect(candidates[0].text == "食べ")
        #expect(candidates[0].reading == "たべ")
        #expect(candidates[1].text == "食べる")
        #expect(candidates[1].reading == "たべ")
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

    @Test("displays the tapped piece: お resolves お, お土産 lands in also")
    func compoundHit() throws {
        let outcome = try #require(try engine.lookup(
            segments: [LookupSegment(surface: "お"), LookupSegment(surface: "土産", lemma: "土産")],
            tappedAt: 0,
            sentenceText: "お土産"
        ))

        #expect(outcome.display.matched == "お")
        #expect(outcome.display.entries.map(\.entSeq) == [9_990_040])
    }

    @Test("displays the join when the tapped piece alone misses")
    func joinFallbackHit() throws {
        let outcome = try #require(try engine.lookup(
            segments: [LookupSegment(surface: "お土"), LookupSegment(surface: "産", lemma: "産")],
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

        #expect(outcome.display.matched == "お")
        #expect(outcome.also.map(\.matched) == ["お土産"])
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

    @Test("retains the longer-join hits that add new entries as results")
    func shorterHitsRetained() throws {
        let outcome = try #require(try engine.lookup(
            segments: [LookupSegment(surface: "お"), LookupSegment(surface: "土産", lemma: "土産")],
            tappedAt: 0,
            sentenceText: "お土産"
        ))

        #expect(outcome.also.map(\.matched) == ["お土産"])
        #expect(outcome.also[0].entries.map(\.entSeq) == [1_002_500])
    }

    @Test("split fallback surfaces the single-kanji entries of a whole-word miss")
    func splitFallbackHit() throws {
        let outcome = try #require(try engine.lookup(
            segments: [LookupSegment(surface: "雨尾")],
            tappedAt: 0,
            sentenceText: "雨尾"
        ))

        // 雨尾 is no headword: the split candidates resolve both kanji.
        #expect(outcome.display.matched == "雨")
        #expect(outcome.display.entries.map(\.entSeq) == [9_990_030])
        #expect(outcome.also.map(\.matched) == ["尾"])
        #expect(outcome.also[0].entries.map(\.entSeq) == [9_990_040])
    }

    @Test("a compound hit displays and its split hits trail in also")
    func compoundDisplaySplitsTrail() throws {
        // 風通し keeps the also-list empty — the 風通 / 風 / 通 splits all
        // miss the fixture (風呂敷 can't: the boundary-crossing 呂敷 split
        // resolves the synthetic entry).
        let outcome = try #require(try engine.lookup(
            segments: [LookupSegment(surface: "風通し")],
            tappedAt: 0,
            sentenceText: "風通し"
        ))

        #expect(outcome.display.matched == "風通し")
        #expect(outcome.display.entries.map(\.entSeq) == [1_500_010])
        #expect(outcome.also.isEmpty)
    }

    @Test("a cross-boundary split of the join trails in also")
    func joinedSplitCrossBoundaryHit() throws {
        let outcome = try #require(try engine.lookup(
            segments: [LookupSegment(surface: "風呂"), LookupSegment(surface: "敷")],
            tappedAt: 0,
            sentenceText: "風呂敷"
        ))

        // The join 風呂敷 displays; the tapped surface's splits (風, 呂)
        // miss the fixture and the boundary-crossing 呂敷 split resolves
        // the compound's inner word as an "also:" result.
        #expect(outcome.display.matched == "風呂敷")
        #expect(outcome.display.entries.map(\.entSeq) == [1_500_150])
        #expect(outcome.also.map(\.matched) == ["呂敷"])
        #expect(outcome.also[0].entries.map(\.entSeq) == [9_990_090])
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
