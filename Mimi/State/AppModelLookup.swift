import Foundation

/// The app's single dictionary popover anchor: which surface owns it, the
/// result it shows, and the paged entry index (a candidate can match
/// several entries — the pager walks them reading-match first, then
/// common-first, then `ent_seq`).
struct SelectedLookup: Equatable, Identifiable, Sendable {
    /// Where the popover is anchored. One popover app-wide: only the
    /// surface whose source matches presents it. The transcript anchor is
    /// the tapped word itself — `tokenIndex` is the segment index into the
    /// annotator segments the row rendered from — so the arrow points at
    /// the word, not the row.
    enum Source: Equatable, Hashable, Sendable {
        case transcript(sentenceIndex: Int, tokenIndex: Int)
        case liveStrip
    }

    var result: LookupResult
    var source: Source
    var entryIndex: Int

    /// Presentation identity. Popover presentation is keyed on `source`
    /// alone (a same-source retap swaps the content in place); the id
    /// distinguishes results for debugging and tests, and stays stable
    /// across entry paging (a page turn updates contents, not identity).
    var id: String {
        "\(source)-\(result.matched)"
    }
}

extension SelectedLookup {
    /// The popover item a given surface presents — only the surface whose
    /// anchor matches `source` shows the popover; every other surface sees
    /// nothing. Pure for tests.
    func popoverItem(for source: Source) -> SelectedLookup? {
        self.source == source ? self : nil
    }
}

/// The pinned sidebar DICTIONARY card content: the last lookup of the
/// session plus its "also:" shorter hits. Persists after the popover
/// dismisses; cleared on session clear.
struct PinnedLookup: Equatable, Sendable {
    var result: LookupResult
    var also: [LookupResult]
    var entryIndex: Int
}

/// A lookup failure that belongs to the annotator, not the dictionary
/// engine: the tokenizer dictionary was unavailable, so the tap resolved
/// to no segments to expand. Surfaces through the `dictionaryLookup`
/// toast — the warning pill stays reserved for genuine no-hit misses.
enum LookupPipelineError: LocalizedError {
    case annotatorUnavailable

    var errorDescription: String? {
        "Text annotation is unavailable; the tokenizer dictionary may still be preparing."
    }
}

extension AppModel {

    // MARK: - Tap entry point

    /// UI entry for a dictionary-mode tap: re-resolves the rendered
    /// segments at tap time (cached for unchanged text; live partials use
    /// their tap-time snapshot), maps them into the value snapshots forward
    /// expansion consumes — surface, kana reading (furigana; a kana-only
    /// surface is its own reading), lemma — and runs the lookup on a
    /// background task. UI state is only ever touched back on the main actor.
    func handleLookupTap(_ token: LookupToken, source: SelectedLookup.Source) {
        let segments = ReadingAnnotator.segments(for: token.sentenceText)?
            .map { LookupSegment(
                surface: $0.surface,
                lemma: $0.lemma,
                reading: Self.lookupReading(for: $0)
            ) }
        lookupGeneration &+= 1
        let generation = lookupGeneration
        Task {
            await runLookup(
                segments: segments,
                tappedAt: token.tokenIndex,
                sentenceText: token.sentenceText,
                surface: token.surface,
                source: source,
                generation: generation
            )
        }
    }

    /// The tap's kana reading for a rendered segment: the furigana when the
    /// annotator aligned one, else the surface itself when kana-only (kana
    /// carries its pronunciation by construction — the annotator's own
    /// self-reading rule). Reading-less kanji, numerals, and plain runs
    /// carry none: the lookup ranking then ignores readings entirely.
    private static func lookupReading(for segment: ReadingSegment) -> String? {
        if let furigana = segment.furigana, !furigana.isEmpty {
            return furigana
        }
        guard !segment.surface.isEmpty,
              segment.surface.unicodeScalars.allSatisfy(KanaClassification.isKana)
        else { return nil }
        return segment.surface
    }

    /// Runs the expansion + database queries off-main and applies the
    /// outcome on main. Internal and fully parameterized so tests await it
    /// directly over an injected fixture engine (`generation` nil skips the
    /// staleness check). nil segments (empty tapped text) end at the
    /// no-hit pill; empty segments (the annotator ran without its
    /// dictionary) surface the annotator-unavailable error instead.
    func runLookup(
        segments: [LookupSegment]?, tappedAt: Int, sentenceText: String,
        surface: String, source: SelectedLookup.Source, generation: Int? = nil
    ) async {
        let engine = jmDictLookup
        let outcome: Result<LookupOutcome?, Error> = await Task.detached(
            priority: .userInitiated
        ) {
            guard let segments else { return .success(nil) }
            guard !segments.isEmpty else {
                return .failure(LookupPipelineError.annotatorUnavailable)
            }
            do {
                return try .success(engine.lookup(
                    segments: segments, tappedAt: tappedAt, sentenceText: sentenceText
                ))
            } catch {
                return .failure(error)
            }
        }.value
        if let generation, generation != lookupGeneration {
            return
        }
        finishLookup(outcome, surface: surface, source: source)
    }

    /// Applies a finished lookup: a hit selects + pins (popover anchor and
    /// sidebar card update together), a miss posts the amber warning pill
    /// (popover stays nil, pinned untouched), an infrastructure error posts
    /// the `dictionaryLookup` toast (never the pill).
    private func finishLookup(
        _ outcome: Result<LookupOutcome?, Error>, surface: String,
        source: SelectedLookup.Source
    ) {
        switch outcome {
        case .success(nil):
            notices.post(
                message: "No dictionary entry for \"\(surface)\"", tone: .warning
            )
        case let .success(.some(outcome)):
            selectedLookup = SelectedLookup(
                result: outcome.display, source: source, entryIndex: 0
            )
            pinnedLookup = PinnedLookup(
                result: outcome.display, also: outcome.also, entryIndex: 0
            )
        case let .failure(error):
            toasts.post(
                key: ToastKey.dictionaryLookup, style: .yellowAuto,
                title: "Dictionary lookup failed", body: error.localizedDescription
            )
        }
    }

    // MARK: - Popover lifecycle

    /// The popover's set-nil path (dismiss, Escape): clears the selection
    /// only when the dismissing surface owns the anchor, so a stale binding
    /// from a virtualized-off-screen row can never clobber a newer
    /// selection. Pinned state persists.
    func dismissLookupPopover(source: SelectedLookup.Source) {
        if selectedLookup?.source == source {
            selectedLookup = nil
        }
    }

    // MARK: - "also:" pills

    /// Re-selects an "also:" candidate: the pinned card and the live
    /// popover (when one is up) switch to the tapped result, and the pill
    /// row recomputes from the retained expansion results relative to the
    /// new selection — no new query runs.
    func selectAlsoPill(_ result: LookupResult) {
        guard let pinned = pinnedLookup else { return }
        let source = selectedLookup?.source
        let hadSelection = selectedLookup != nil
        let others = ([pinned.result] + pinned.also).filter { $0 != result }
        pinnedLookup = PinnedLookup(result: result, also: others, entryIndex: 0)
        if hadSelection, let source {
            selectedLookup = SelectedLookup(
                result: result, source: source, entryIndex: 0
            )
        }
    }

    // MARK: - Entry pager

    /// Turns the `◀ i/N ▶` pager to `index` (clamped): popover and pinned
    /// card page together, both showing the selected entry.
    func stepLookupEntry(to index: Int) {
        guard let count = selectedLookup?.result.entries.count ?? pinnedLookup?.result.entries.count,
              count > 0
        else { return }
        let clamped = min(max(index, 0), count - 1)
        selectedLookup?.entryIndex = clamped
        pinnedLookup?.entryIndex = clamped
    }
}
