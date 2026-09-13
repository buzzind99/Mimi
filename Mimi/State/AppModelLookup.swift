import Foundation

/// The content a finished lookup pins, shared by the popover selection and
/// the sidebar card: a hit with its display result, the retained "also:"
/// fallback hits, and the origin the display result came from (a join lead
/// is labeled; a tap-promoted pill reads as the tapped word); or a
/// not-found tap — the tapped word has no entry — with the deep split
/// fallback hits demoted to "related:" suggestions.
enum LookupContent: Equatable, Sendable {
    case found(result: LookupResult, also: [LookupResult], origin: ExpansionOrigin)
    case notFound(surface: String, related: [LookupResult])

    /// The display result when found.
    var displayResult: LookupResult? {
        switch self {
        case let .found(result, _, _): result
        case .notFound: nil
        }
    }

    /// The demoted fallback hits: "also:" for a found state, "related:"
    /// for a not-found one.
    var fallbackResults: [LookupResult] {
        switch self {
        case let .found(_, also, _): also
        case let .notFound(_, related): related
        }
    }

    /// The display result followed by the demoted fallback hits — the full
    /// result set a fallback-pill re-selection filters against.
    var allResults: [LookupResult] {
        ([displayResult] + fallbackResults).compactMap(\.self)
    }
}

/// The app's single dictionary popover anchor: which surface owns it, the
/// content it shows, and the paged entry index (a candidate can match
/// several entries — the pager walks them surface-writing match first,
/// then reading-match, then common-first, then `ent_seq`).
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

    var content: LookupContent
    var source: Source
    var entryIndex: Int

    /// Presentation identity. Popover presentation is keyed on `source`
    /// alone (a same-source retap swaps the content in place); the id
    /// distinguishes results for debugging and tests, and stays stable
    /// across entry paging (a page turn updates contents, not identity).
    var id: String {
        let token: String = switch content {
        case let .found(result, _, _): result.matched
        case let .notFound(surface, _): "not-found:\(surface)"
        }
        return "\(source)-\(token)"
    }
}

extension SelectedLookup {
    /// The popover item a given surface presents — only the surface whose
    /// anchor matches `source` shows the popover; every other surface sees
    /// nothing. Pure helper.
    func popoverItem(for source: Source) -> SelectedLookup? {
        self.source == source ? self : nil
    }
}

/// The pinned sidebar DICTIONARY card content: the last lookup of the
/// session — hit or not-found — with the paged entry index. Persists after
/// the popover dismisses; cleared on session clear.
struct PinnedLookup: Equatable, Sendable {
    var content: LookupContent
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
    /// resolution on main. Internal and fully parameterized so tests await
    /// it directly over an injected fixture engine (`generation` nil skips
    /// the staleness check). nil segments (empty tapped text) end at the
    /// no-hit pill; empty segments (the annotator ran without its
    /// dictionary) surface the annotator-unavailable error instead.
    func runLookup(
        segments: [LookupSegment]?, tappedAt: Int, sentenceText: String,
        surface: String, source: SelectedLookup.Source, generation: Int? = nil
    ) async {
        let engine = jmDictLookup
        let resolution: Result<LookupResolution?, Error> = await Task.detached(
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
        finishLookup(resolution, surface: surface, source: source)
    }

    /// Applies a finished lookup: a found tap selects + pins (popover
    /// anchor and sidebar card update together); a not-found tap with
    /// related fallback hits pins the not-found state the same way — only
    /// a tap nothing resolved (no hit at all) posts the amber warning pill;
    /// an infrastructure error posts the `dictionaryLookup` toast (never
    /// the pill).
    private func finishLookup(
        _ resolution: Result<LookupResolution?, Error>, surface: String,
        source: SelectedLookup.Source
    ) {
        switch resolution {
        case let .success(resolved):
            // A resolved tap pins when anything resolved at all — a found
            // hit, or a not-found with related fallback hits; a bare miss
            // (nothing resolved) posts the amber warning pill instead.
            if let content = resolved.flatMap({ Self.lookupContent(for: $0, surface: surface) }) {
                presentLookup(content: content, source: source)
            } else {
                notices.post(
                    message: "No dictionary entry for \"\(surface)\"", tone: .warning
                )
            }
        case let .failure(error):
            toasts.post(
                key: ToastKey.dictionaryLookup, style: .yellowAuto,
                title: "Dictionary lookup failed", body: error.localizedDescription
            )
        }
    }

    /// The content a resolved tap pins, or nil when nothing resolved at
    /// all — a not-found resolution without related hits is a bare miss,
    /// and posts the warning pill instead of pinning an empty card.
    private static func lookupContent(
        for resolved: LookupResolution, surface: String
    ) -> LookupContent? {
        switch resolved {
        case let .found(outcome):
            .found(
                result: outcome.display, also: outcome.also,
                origin: outcome.displayOrigin
            )
        case let .notFound(related):
            related.isEmpty ? nil : .notFound(surface: surface, related: related)
        }
    }

    /// Presents a resolved lookup: pins the sidebar card and, when a source
    /// is supplied (a popover is up), anchors the popover to the same content.
    /// Both start at entry 0, keeping the two surfaces from drifting apart.
    private func presentLookup(content: LookupContent, source: SelectedLookup.Source?) {
        pinnedLookup = PinnedLookup(content: content, entryIndex: 0)
        if let source {
            selectedLookup = SelectedLookup(content: content, source: source, entryIndex: 0)
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

    // MARK: - Fallback pills

    /// Selects a fallback pill — an "also:" hit on a found card, or a
    /// "related:" suggestion on a not-found one (its promotion): the
    /// pinned card and the live popover (when one is up) switch to that
    /// result as found, and the pill row recomputes from the retained
    /// results relative to the new selection — no new query runs. The
    /// promoted result carries the tapped-surface origin: an explicitly
    /// chosen hit is never labeled a fallback lead.
    func selectAlsoPill(_ result: LookupResult) {
        guard let pinned = pinnedLookup else { return }
        let source = selectedLookup?.source
        let others = pinned.content.allResults.filter { $0 != result }
        let content = LookupContent.found(
            result: result, also: others, origin: .tappedSurface
        )
        presentLookup(content: content, source: source)
    }

    // MARK: - Entry pager

    /// Turns the `◀ i/N ▶` pager to `index` (clamped): popover and pinned
    /// card page together, both showing the selected entry. A not-found
    /// pin has no entries; the pager is inert.
    func stepLookupEntry(to index: Int) {
        let content = selectedLookup?.content ?? pinnedLookup?.content
        guard let count = content?.displayResult?.entries.count, count > 0
        else { return }
        let clamped = min(max(index, 0), count - 1)
        selectedLookup?.entryIndex = clamped
        pinnedLookup?.entryIndex = clamped
    }
}
