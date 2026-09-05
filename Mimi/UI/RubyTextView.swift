import SwiftUI

/// Wrapping flow layout: places children left-to-right, breaking onto a new
/// line when the next child would exceed the available width. Child sizes are
/// measured once per content change (keyed by `fingerprint`) and line breaks
/// are packed per proposal width, so the repeated layout passes List's
/// virtualized rows trigger (scroll materialization, insertion springs,
/// re-anchor chases) don't re-measure every child each time. The fingerprint
/// also guards row recycling: a reused layout instance re-measures when its
/// content changes.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 1
    /// Identifies the content that produced the children; while it is
    /// unchanged, cached sizes and line breaks are reused.
    var fingerprint: String

    struct Cache {
        var fingerprint = ""
        var sizes: [CGSize] = []
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
                cache.sizes[index].width > bounds.width
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
        // wraps internally instead of overflowing the row. Their wrapped
        // height keeps following children on a lower line.
        var sizes = cache.sizes
        if width.isFinite {
            for (index, size) in cache.sizes.enumerated() where size.width > width {
                sizes[index] = subviews[index].sizeThatFits(
                    ProposedViewSize(width: width, height: nil)
                )
            }
        }
        var placements: [CGPoint] = []
        placements.reserveCapacity(sizes.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for size in sizes {
            if x > 0, x + spacing + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            placements.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        cache.placements = placements
        cache.totalSize = CGSize(
            width: width.isFinite ? width : max(0, x - spacing),
            height: y + rowHeight
        )
    }
}

/// Ruby-style annotation: each kana/kanji word renders with its romaji
/// beneath it (or kana furigana above it), wrapping like normal text. Runs
/// without a distinct reading (punctuation, Latin, digits; kanji runs whose
/// romaji doesn't reverse to kana) render inline as plain text, so their
/// surfaces stay top-aligned with annotated words on the same line.
/// Consecutive plain runs fold into a single flow child.
struct RubyTextView: View, Equatable {
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

    var body: some View {
        let units = displayUnits
        if annotation != .none, units.contains(where: \.isAnnotated) {
            FlowLayout(spacing: 4, lineSpacing: 1, fingerprint: fingerprint) {
                ForEach(Array(units.enumerated()), id: \.offset) { _, unit in
                    unitView(unit)
                }
            }
        } else if !units.isEmpty {
            // Nothing annotatable: plain text keeps the slot filled.
            if reservesAnnotationLine {
                VStack(spacing: 0) {
                    reservedAnnotationLine
                    Text(verbatim: text)
                        .font(surfaceFont)
                        .italic(surfaceItalic)
                }
            } else {
                Text(verbatim: text)
                    .font(surfaceFont)
                    .italic(surfaceItalic)
            }
        }
    }

    private enum DisplayUnit {
        case plain(String)
        case annotated(surface: String, note: String)

        var isAnnotated: Bool {
            guard case .annotated = self else { return false }
            return true
        }
    }

    /// Pins FlowLayout's size cache: annotation mode and the italic flag
    /// change child structure, the fonts change child sizes, the text changes
    /// surfaces. Colors paint only, so they are excluded.
    private var fingerprint: String {
        "\(annotation)-\(surfaceItalic)-\(surfaceFont.hashValue)-\(noteFont.hashValue)-\(text)"
    }

    /// Segments folded for rendering: consecutive runs without a distinct
    /// reading merge into one `.plain` child (whitespace and punctuation
    /// arrive as separate segments from the annotator).
    private var displayUnits: [DisplayUnit] {
        guard let segments = ReadingAnnotator.segments(for: text) else { return [] }
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
            plainRun(run)
        case let .annotated(surface, note):
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
                    Text(verbatim: surface)
                        .font(surfaceFont)
                        .italic(surfaceItalic)
                } else {
                    Text(verbatim: surface)
                        .font(surfaceFont)
                        .italic(surfaceItalic)
                    Text(verbatim: note)
                        .font(noteFont)
                        .foregroundStyle(annotationColor)
                        .lineLimit(1)
                }
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
    private func plainRun(_ surface: String) -> some View {
        if annotation == .furigana || reservesAnnotationLine {
            VStack(spacing: 0) {
                reservedAnnotationLine
                Text(verbatim: surface)
                    .font(surfaceFont)
                    .italic(surfaceItalic)
            }
        } else {
            Text(verbatim: surface)
                .font(surfaceFont)
                .italic(surfaceItalic)
        }
    }
}
