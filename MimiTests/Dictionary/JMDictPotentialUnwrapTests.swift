import Foundation
@testable import Mimi
import Testing

/// The potential-form lemma unwrap: IPADIC lexicalizes potential forms as
/// standalone verbs whose base is the potential itself (作れる), which
/// misses the JMDict headword index — the expansion queries the unwrapped
/// dictionary form (作る) as a second lemma candidate behind it.
@Suite("JMDictExpansion potential unwrap")
final class JMDictPotentialUnwrapTests {
    private func segments(_ pairs: (surface: String, lemma: String?)...) -> [LookupSegment] {
        pairs.map { LookupSegment(surface: $0.surface, lemma: $0.lemma) }
    }

    @Test("a potential-form lemma gains the source-verb candidate behind it")
    func potentialLemmaUnwraps() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("作れ", "作れる"), ("ない", nil)),
            tappedAt: 0,
            sentenceText: "作れない"
        )

        #expect(candidates.map(\.candidate.text) == [
            "作れ", "作れる", "作る", "作れない", "作"
        ])
        #expect(candidates.map(\.origin) == [
            .tappedSurface, .tappedLemma, .tappedLemma, .join, .split
        ])
    }

    @Test("a られる lemma unwraps past the tail behind the lemma itself")
    func rareruLemmaUnwraps() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("食べられ", "食べられる")),
            tappedAt: 0,
            sentenceText: "食べられ"
        )

        #expect(candidates.map(\.candidate.text) == [
            "食べられ", "食べられる", "食べる", "食"
        ])
    }

    @Test("the unwrapped potential candidate carries the tapped segment's reading")
    func potentialUnwrapCarriesReading() {
        let candidates = JMDictExpansion.candidates(
            segments: [LookupSegment(surface: "作れ", lemma: "作れる", reading: "つくれ")],
            tappedAt: 0,
            sentenceText: "作れ"
        )

        #expect(candidates.map(\.candidate.text) == ["作れ", "作れる", "作る", "作"])
        #expect(candidates.map(\.candidate.reading) == ["つくれ", "つくれ", "つくれ", nil])
    }

    @Test("a potential surface whose lemma equals it still unwraps behind the surface")
    func potentialSurfaceLemmaUnwraps() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("見れる", "見れる")),
            tappedAt: 0,
            sentenceText: "見れる"
        )

        #expect(candidates.map(\.candidate.text) == ["見れる", "見る", "見"])
    }

    @Test("the unwrapped form never repeats the tapped surface's own query")
    func potentialUnwrapSurfaceDeduplicated() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("作る", "作れる")),
            tappedAt: 0,
            sentenceText: "作る"
        )

        #expect(candidates.map(\.candidate.text) == ["作る", "作れる", "作"])
    }

    @Test("every え-row potential tail shifts onto its う-row counterpart", arguments: [
        ("作れる", "作る"), ("見れる", "見る"), ("食べれる", "食べる"), ("寝れる", "寝る"),
        ("書ける", "書く"), ("泳げる", "泳ぐ"), ("話せる", "話す"), ("待てる", "待つ"),
        ("遊べる", "遊ぶ"), ("読める", "読む"), ("死ねる", "死ぬ"), ("洗える", "洗う")
    ])
    func potentialTailShift(input: String, expected: String) {
        #expect(JMDictExpansion.dictionaryForm(ofPotential: input) == expected)
    }

    @Test("a られる lemma unwraps to the source verb", arguments: [
        ("食べられる", "食べる"), ("起きられる", "起きる"), ("作られる", "作る"),
        ("見られる", "見る")
    ])
    func rareruTail(input: String, expected: String) {
        #expect(JMDictExpansion.dictionaryForm(ofPotential: input) == expected)
    }

    @Test("lemmas that don't shape like a potential unwrap to nil", arguments: [
        "言う", "出来る", "食べた", "だ", "る", "ぬる", "行った"
    ])
    func nonPotentialLemma(input: String) {
        #expect(JMDictExpansion.dictionaryForm(ofPotential: input) == nil)
    }
}
