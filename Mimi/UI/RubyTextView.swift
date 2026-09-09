import AppKit
import SwiftUI

/// Wrapping flow layout: places children left-to-right, breaking onto a new
/// line when the next child would exceed the available width. Child sizes are
/// measured once per content change (keyed by `fingerprint`) and line breaks
/// are packed per proposal width, so the repeated layout passes List's
/// virtualized rows trigger (scroll materialization, insertion springs,
/// re-anchor chases) don't re-measure every child each time. The fingerprint
/// also guards row recycling: a reused layout instance re-measures when its
/// content changes.
/// Pure placement pass for `FlowLayout`: packs children left-to-right,
/// wrapping to a new line when the next child would exceed the available
/// width. Children flagged in `wraps` re-wrap internally (they were
/// re-measured to fit the line, so they span multiple visual lines), and a
/// row always closes after one — the next child starts on a fresh line
/// below it, never beside its lower lines.
struct RubyFlowPacking: Equatable {
    var placements: [CGPoint]
    var totalSize: CGSize

    static func pack(
        sizes: [CGSize], wraps: [Bool], width: CGFloat,
        spacing: CGFloat, lineSpacing: CGFloat
    ) -> RubyFlowPacking {
        var placements: [CGPoint] = []
        placements.reserveCapacity(sizes.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        // A closed wrapped row owes its inter-line gap to the next child; the
        // gap is applied lazily so a wrapped child that ends the content
        // doesn't add a trailing `lineSpacing` to the total height.
        var gapOwed = false
        for (index, size) in sizes.enumerated() {
            if x == 0, gapOwed {
                y += lineSpacing
                gapOwed = false
            }
            if x > 0, x + spacing + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            placements.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            if wraps[index] {
                x = 0
                y += rowHeight
                rowHeight = 0
                gapOwed = true
            }
        }
        return RubyFlowPacking(
            placements: placements,
            totalSize: CGSize(
                width: width.isFinite ? width : max(0, x - spacing),
                height: y + rowHeight
            )
        )
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 1
    /// Identifies the content that produced the children; while it is
    /// unchanged, cached sizes and line breaks are reused.
    var fingerprint: String

    struct Cache {
        var fingerprint = ""
        var sizes: [CGSize] = []
        /// Children re-measured under `packedWidth` because their ideal width
        /// exceeded the line, keyed by index. Kept separate from `sizes` so
        /// the cached ideal measurements — which invalidation compares
        /// against — never become width-dependent.
        var fitted: [Int: CGSize] = [:]
        var packedWidth: CGFloat?
        var placements: [CGPoint] = []
        var totalSize = CGSize.zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        let unchanged = cache.fingerprint == fingerprint
            && cache.sizes.count == subviews.count
            && subviews.first.map { $0.sizeThatFits(.unspecified) } == cache.sizes.first
        guard !unchanged else { return }
        cache.fingerprint = fingerprint
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.fitted = [:]
        cache.packedWidth = nil
        cache.placements = []
        cache.totalSize = .zero
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        measureIfNeeded(subviews: subviews, into: &cache)
        pack(width: proposal.width ?? .infinity, subviews: subviews, cache: &cache)
        return cache.totalSize
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) {
        measureIfNeeded(subviews: subviews, into: &cache)
        pack(width: bounds.width, subviews: subviews, cache: &cache)
        for (index, subview) in zip(cache.placements.indices, subviews) {
            // A child re-measured to fit the line must be placed under the
            // same width proposal, or it re-expands to its ideal single-line
            // width and overflows the row (a folded plain run in furigana
            // mode can be wider than the whole transcript).
            let proposal: ProposedViewSize =
                cache.fitted[index] != nil
                    ? ProposedViewSize(width: bounds.width, height: nil)
                    : .unspecified
            subview.place(
                at: CGPoint(
                    x: bounds.minX + cache.placements[index].x,
                    y: bounds.minY + cache.placements[index].y
                ),
                anchor: .topLeading,
                proposal: proposal
            )
        }
    }

    private func measureIfNeeded(subviews: Subviews, into cache: inout Cache) {
        guard cache.sizes.count != subviews.count else { return }
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.packedWidth = nil
    }

    private func pack(
        width: CGFloat, subviews: Subviews, cache: inout Cache
    ) {
        guard cache.packedWidth != width else { return }
        cache.packedWidth = width
        // Children wider than the line can't be split by the flow packer;
        // re-measure them under the line's width so their content (Text)
        // wraps internally instead of overflowing the row. A wrapping child
        // consumes its whole row: the packer closes the line after it so no
        // sibling floats beside its lower lines.
        var sizes = cache.sizes
        var wraps = [Bool](repeating: false, count: sizes.count)
        cache.fitted = [:]
        if width.isFinite {
            for (index, size) in cache.sizes.enumerated() where size.width > width {
                let fittedSize = subviews[index].sizeThatFits(
                    ProposedViewSize(width: width, height: nil)
                )
                sizes[index] = fittedSize
                wraps[index] = true
                cache.fitted[index] = fittedSize
            }
        }
        let packing = RubyFlowPacking.pack(
            sizes: sizes, wraps: wraps, width: width,
            spacing: spacing, lineSpacing: lineSpacing
        )
        cache.placements = packing.placements
        cache.totalSize = packing.totalSize
    }
}

/// Ruby-style annotation: each kana/kanji word renders with its romaji
/// beneath it (or kana furigana above it), wrapping like normal text. Runs
/// without a distinct reading (punctuation, Latin, digits; kanji runs whose
/// romaji doesn't reverse to kana) render inline as plain text, so their
/// surfaces stay top-aligned with annotated words on the same line.
/// Consecutive plain runs fold into a single flow child.
struct RubyTextView: View, @preconcurrency Equatable {
    let text: String
    var annotation: ReadingAnnotation = .romaji
    var surfaceFont: Font
    var annotationFont: Font
    /// Overrides `annotationFont` for the kana reading shown above the
    /// surface in furigana mode; romaji keeps `annotationFont`. Falls back
    /// to `annotationFont` when unset.
    var furiganaFont: Font?
    var annotationColor: Color
    var surfaceItalic = false
    /// Opt-in for hosts whose slot must hold a fixed geometry: when set, every
    /// unit — annotated or plain, in every annotation mode — reserves the
    /// annotation line above the surface (the visible furigana in furigana
    /// mode, invisible in romaji/none). The surface then starts at the same
    /// vertical position in None, Romaji, and Furigana modes, so mode toggles
    /// never shift the kanji. Off by default; `TranscriptRow` relies on it.
    var reservesAnnotationLine = false
    /// Whether render-time segment resolutions go through the annotator's
    /// cache. Hosts rendering a live partial — a growing 6–10 Hz revision of
    /// the in-flight sentence — opt out: every revision is a distinct string
    /// that will never be queried again, so caching it only churns the
    /// store. The tap-time re-resolution (`lookupAction`) stays cached
    /// regardless. Excluded from `==` (no effect on rendered output).
    var cachesSegments = true
    /// Click behavior for surfaces (sidebar "cursor mode"): `.copy` invokes
    /// `onCopy` with the clicked run; `.dictionary` opens a definition
    /// lookup for the tapped word via `onLookup` (falling back to this
    /// legacy path where the host passes no handler); `.none` leaves
    /// clicks inert.
    var cursorMode: CursorMode = .none
    /// Invoked with the clicked surface text when `cursorMode == .copy`; the
    /// host owns the pasteboard write and the confirmation toast.
    var onCopy: ((String) -> Void)?
    /// Invoked with the tapped word when `cursorMode == .dictionary` and a
    /// token-derived surface is clicked; the host owns the lookup, its
    /// result presentation, and error surfacing. When nil, `.dictionary`
    /// renders the legacy path and taps stay inert (the HUD).
    var onLookup: ((LookupToken) -> Void)?
    /// Per-word popover presentation for the transcript host: invoked with
    /// a word unit's segment index at render time; a non-nil result
    /// attaches `.popover` to that word, and only the anchor word's
    /// binding is true, so the arrow points at the word. nil — the HUD,
    /// the live strip — keeps word units popover-free. Excluded from `==`
    /// (closures carry no value identity); the host's anchor field covers
    /// the data change that must re-render the row.
    var lookupPopover: ((Int) -> LookupPopover?)?

    /// One word unit's popover presentation, resolved by the host per
    /// segment index: the binding presents only while that word is the
    /// selection's anchor; the content is the shared entry view (nil until
    /// a selection lands — the binding is false then, so nothing presents).
    struct LookupPopover {
        let isPresented: Binding<Bool>
        let content: DictionaryPopoverView?
    }

    /// Dictionary mode is active only when the host handles lookups; with
    /// `onLookup == nil` (the HUD) it falls back to the legacy path and
    /// taps stay inert.
    var dictionaryLookupActive: Bool {
        cursorMode == .dictionary && onLookup != nil
    }

    /// One child of the dictionary-mode flow layout. Every annotator
    /// segment is its own unit — token-derived words tappable, whitespace
    /// and punctuation inert — with no plain-run folding, so the unit's
    /// position in the array is the tapped segment index.
    enum SegmentedUnit: Equatable {
        /// A token-derived segment: tappable in dictionary mode, annotated
        /// when `note` is set (furigana above / romaji beneath per mode).
        case word(surface: String, note: String?)
        /// Whitespace or punctuation: renders plain, never tappable.
        case inert(surface: String)
    }

    /// Pure segment→child mapping for the dictionary path: a segment is
    /// inert when it is whitespace-only or carries no letter or number
    /// (punctuation); everything else is a tappable word — including
    /// reading-less kanji, whose tap falls back to a surface query. The
    /// note follows the annotation mode and is shown only when it differs
    /// from the surface, matching the legacy path's annotated-unit rule.
    static func segmentedUnits(
        for segments: [ReadingSegment], annotation: ReadingAnnotation
    ) -> [SegmentedUnit] {
        segments.map { segment in
            let surface = segment.surface
            let inert = surface.allSatisfy { $0.isWhitespace }
                || !surface.contains(where: { $0.isLetter || $0.isNumber })
            guard !inert else { return .inert(surface: surface) }
            let note: String?
            switch annotation {
            case .none: note = nil
            case .furigana: note = segment.furigana
            case .romaji: note = segment.romaji
            }
            return .word(surface: surface, note: note == surface ? nil : note)
        }
    }

    /// The body the dictionary path renders for the resolved segments: the
    /// flow of per-segment units, or the plain fallback when the annotator
    /// yielded nothing at all (nil — unresolvable text — or empty, the
    /// tokenizer-dictionary-unavailable case), so the row never blanks.
    /// Pure for tests.
    enum SegmentedBodyPlan: Equatable {
        case flow([SegmentedUnit])
        case plain
    }

    static func segmentedBodyPlan(
        segments: [ReadingSegment]?, annotation: ReadingAnnotation
    ) -> SegmentedBodyPlan {
        guard let segments, !segments.isEmpty else { return .plain }
        return .flow(segmentedUnits(for: segments, annotation: annotation))
    }

    /// The tap payload for segment `index`: surface, best-known reading,
    /// lemma, segment index, and the full sentence text. Pure over the
    /// resolved segments; the tap path re-resolves `segments(for: text)`
    /// first (cached for unchanged text) so a live partial that grew
    /// between render and tap yields its tap-time snapshot.
    static func lookupToken(
        at index: Int, text: String, segments: [ReadingSegment]?
    ) -> LookupToken? {
        guard let segments, segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        return LookupToken(
            surface: segment.surface,
            reading: segment.furigana,
            lemma: segment.lemma,
            tokenIndex: index,
            sentenceText: text
        )
    }

    private struct SurfaceText: View {
        let text: String
        let font: Font
        var italic = false
        var hoverColor = Theme.accentPink
        var action: (() -> Void)?

        @State private var hovering = false

        var body: some View {
            Text(verbatim: text)
                .font(font)
                .italic(italic)
                .foregroundStyle(hovering ? AnyShapeStyle(hoverColor) : AnyShapeStyle(.primary))
                .textSelection(.disabled)
                .onHover { hovering = $0 }
                .pointerStyle(action == nil ? nil : .link)
                .onTapGesture { action?() }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }

    private func hoverableSurface(_ text: String, action: (() -> Void)? = nil) -> some View {
        SurfaceText(
            text: text, font: surfaceFont, italic: surfaceItalic,
            action: action
        )
    }

    /// The surface action on the legacy path: copy-on-click in `.copy`
    /// mode, inert otherwise.
    private func copyAction(_ text: String) -> (() -> Void)? {
        guard cursorMode == .copy else { return nil }
        return { onCopy?(text) }
    }

    /// The surface action for a dictionary-mode word unit: re-resolves the
    /// segments at tap time (cached for unchanged text) and hands the host
    /// the tapped word's payload.
    private func lookupAction(at index: Int) -> (() -> Void)? {
        guard let onLookup else { return nil }
        let text = self.text
        return {
            guard let token = Self.lookupToken(
                at: index, text: text, segments: ReadingAnnotator.segments(for: text)
            ) else { return }
            onLookup(token)
        }
    }

    var body: some View {
        if dictionaryLookupActive {
            segmentedBody
        } else {
            annotatedBody
        }
    }

    /// Plain full-text rendering: nothing annotatable (legacy path) or no
    /// segments at all (dictionary path — the tokenizer dictionary is
    /// unavailable), so the raw text keeps the slot filled. Taps stay
    /// inert outside `.copy`.
    @ViewBuilder
    private func plainFallback(_ text: String) -> some View {
        if reservesAnnotationLine {
            VStack(spacing: 0) {
                reservedAnnotationLine
                hoverableSurface(text, action: copyAction(text))
            }
        } else {
            hoverableSurface(text, action: copyAction(text))
        }
    }

    /// Legacy path: annotation-folded units, or plain text when nothing is
    /// annotatable. The HUD and every non-dictionary mode render here.
    @ViewBuilder
    private var annotatedBody: some View {
        let units = displayUnits
        if annotation != .none, units.contains(where: \.isAnnotated) {
            FlowLayout(spacing: 4, lineSpacing: 1, fingerprint: fingerprint) {
                ForEach(Array(units.enumerated()), id: \.offset) { _, unit in
                    unitView(unit)
                }
            }
        } else {
            plainFallback(text)
        }
    }

    /// Dictionary path: one tappable unit per annotator segment — no
    /// plain-run folding, so the flow child's index is the tapped segment
    /// index. With no segments the plain fallback renders instead.
    @ViewBuilder
    private var segmentedBody: some View {
        switch Self.segmentedBodyPlan(
            segments: ReadingAnnotator.segments(for: text, caching: cachesSegments),
            annotation: annotation
        ) {
        case let .flow(units):
            FlowLayout(spacing: 4, lineSpacing: 1, fingerprint: fingerprint) {
                ForEach(Array(units.enumerated()), id: \.offset) { index, unit in
                    segmentedUnitView(unit, at: index)
                }
            }
        case .plain:
            plainFallback(text)
        }
    }

    @ViewBuilder
    private func segmentedUnitView(_ unit: SegmentedUnit, at index: Int) -> some View {
        switch unit {
        case let .word(surface, note):
            wordUnit(surface, note: note, index: index)
        case let .inert(surface):
            plainUnit(surface, action: nil)
        }
    }

    /// A tappable word unit, with the host's `.popover` attached when it
    /// provides one. The modifier stays attached to every word unit for
    /// stable identity — the binding is false (and the content nil) for
    /// all but the anchor word.
    @ViewBuilder
    private func wordUnit(_ surface: String, note: String?, index: Int) -> some View {
        let action = lookupAction(at: index)
        if let popover = lookupPopover?(index) {
            wordContent(surface, note: note, action: action)
                .popover(isPresented: popover.isPresented) {
                    if let content = popover.content {
                        content
                    }
                }
        } else {
            wordContent(surface, note: note, action: action)
        }
    }

    @ViewBuilder
    private func wordContent(
        _ surface: String, note: String?, action: (() -> Void)?
    ) -> some View {
        if let note {
            annotatedUnit(surface, note: note, action: action)
        } else {
            plainUnit(surface, action: action)
        }
    }

    /// Excludes `onCopy`, `onLookup`, and `lookupPopover` (closures have
    /// no value identity). The witness stays MainActor-isolated (SwiftUI
    /// diffs views on the main actor); the conformance is `@preconcurrency`
    /// to permit that.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
            && lhs.annotation == rhs.annotation
            && lhs.surfaceFont == rhs.surfaceFont
            && lhs.annotationFont == rhs.annotationFont
            && lhs.furiganaFont == rhs.furiganaFont
            && lhs.annotationColor == rhs.annotationColor
            && lhs.surfaceItalic == rhs.surfaceItalic
            && lhs.reservesAnnotationLine == rhs.reservesAnnotationLine
            && lhs.cursorMode == rhs.cursorMode
    }

    private enum DisplayUnit {
        case plain(String)
        case annotated(surface: String, note: String)

        var isAnnotated: Bool {
            guard case .annotated = self else { return false }
            return true
        }
    }

    /// Pins FlowLayout's size cache: annotation and cursor mode change
    /// child structure (the dictionary path drops plain-run folding), the
    /// italic flag changes child structure, the fonts change child sizes,
    /// the text changes surfaces. Colors paint only, so they are excluded.
    var fingerprint: String {
        "\(annotation)-\(cursorMode)-\(surfaceItalic)-\(surfaceFont.hashValue)-\(noteFont.hashValue)-\(text)"
    }

    /// Segments folded for rendering: consecutive runs without a distinct
    /// reading merge into one `.plain` child (whitespace and punctuation
    /// arrive as separate segments from the annotator).
    private var displayUnits: [DisplayUnit] {
        guard let segments = ReadingAnnotator.segments(for: text, caching: cachesSegments) else {
            return []
        }
        var units: [DisplayUnit] = []
        units.reserveCapacity(segments.count)
        for segment in segments {
            let note = reading(for: segment)
            if let note, note != segment.surface {
                units.append(.annotated(surface: segment.surface, note: note))
            } else if case let .plain(run)? = units.last {
                units[units.count - 1] = .plain(run + segment.surface)
            } else {
                units.append(.plain(segment.surface))
            }
        }
        return units
    }

    private func reading(for segment: ReadingSegment) -> String? {
        annotation == .furigana ? segment.furigana : segment.romaji
    }

    /// The annotation's font per mode: furigana honors `furiganaFont`, the
    /// other modes use `annotationFont`.
    private var noteFont: Font {
        annotation == .furigana ? (furiganaFont ?? annotationFont) : annotationFont
    }

    /// Invisible spacer matching one annotation line; reserves the furigana
    /// slot so surfaces across modes and units share one vertical position.
    private var reservedAnnotationLine: some View {
        Text(verbatim: " ")
            .font(noteFont)
            .lineLimit(1)
    }

    @ViewBuilder
    private func unitView(_ unit: DisplayUnit) -> some View {
        switch unit {
        case let .plain(run):
            plainUnit(run, action: copyAction(run))
        case let .annotated(surface, note):
            annotatedUnit(surface, note: note, action: copyAction(surface))
        }
    }

    private func annotatedUnit(_ surface: String, note: String, action: (() -> Void)?) -> some View {
        VStack(spacing: 0) {
            // Furigana mode already renders the annotation line above
            // the surface; the reservation is only needed for modes
            // that would otherwise start the surface at the top.
            if annotation != .furigana, reservesAnnotationLine {
                reservedAnnotationLine
            }
            if annotation == .furigana {
                Text(verbatim: note)
                    .font(noteFont)
                    .foregroundStyle(annotationColor)
                    .lineLimit(1)
                    .textSelection(.disabled)
                hoverableSurface(surface, action: action)
            } else {
                hoverableSurface(surface, action: action)
                Text(verbatim: note)
                    .font(noteFont)
                    .foregroundStyle(annotationColor)
                    .lineLimit(1)
                    .textSelection(.disabled)
            }
        }
    }

    /// Furigana sits above the surface, and the flow layout top-aligns its
    /// children — so an unannotated run must reserve an invisible annotation
    /// line to keep its surface on the same baseline as annotated words.
    /// (Romaji sits below the surface, where top alignment already works —
    /// unless `reservesAnnotationLine` asks for the line above as well, to
    /// pin the surface to the same height across all annotation modes.)
    @ViewBuilder
    private func plainUnit(_ surface: String, action: (() -> Void)?) -> some View {
        if annotation == .furigana || reservesAnnotationLine {
            VStack(spacing: 0) {
                reservedAnnotationLine
                hoverableSurface(surface, action: action)
            }
        } else {
            hoverableSurface(surface, action: action)
        }
    }
}
