import SwiftUI

/// Wrapping flow layout: places children left-to-right, breaking onto a new
/// line when the next child would exceed the available width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 1

    private struct Row {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var row = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if row.x > 0, row.x + spacing + size.width > maxWidth {
                row.x = 0
                row.y += row.height + lineSpacing
                row.height = 0
            }
            if row.x > 0 {
                row.x += spacing
            }
            row.x += size.width
            row.height = max(row.height, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : row.x, height: row.y + row.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var row = Row(x: bounds.minX, y: bounds.minY)
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if row.x > bounds.minX,
               row.x - bounds.minX + spacing + size.width > bounds.width
            {
                row.x = bounds.minX
                row.y += row.height + lineSpacing
                row.height = 0
            }
            subview.place(
                at: CGPoint(x: row.x, y: row.y), anchor: .topLeading, proposal: .unspecified
            )
            row.x += size.width + spacing
            row.height = max(row.height, size.height)
        }
    }
}

/// Ruby-style annotation: each kana/kanji word renders with its romaji
/// beneath it (or kana furigana above it), wrapping like normal text. Runs
/// without a distinct reading (punctuation, Latin, digits; kanji runs whose
/// romaji doesn't reverse to kana) render inline as plain text, so their
/// surfaces stay top-aligned with annotated words on the same line.
struct RubyTextView: View {
    let text: String
    var annotation: ReadingAnnotation = .romaji
    var surfaceFont: Font
    var annotationFont: Font
    var annotationColor: Color
    var surfaceItalic = false

    var body: some View {
        if let segments = ReadingAnnotator.segments(for: text) {
            if annotation != .none,
               segments.contains(where: { reading(for: $0) != nil && reading(for: $0) != $0.surface })
            {
                FlowLayout(spacing: 4, lineSpacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if let note = reading(for: segment), note != segment.surface {
                            VStack(spacing: 0) {
                                if annotation == .furigana {
                                    Text(verbatim: note)
                                        .font(annotationFont)
                                        .foregroundStyle(annotationColor)
                                        .lineLimit(1)
                                    Text(verbatim: segment.surface)
                                        .font(surfaceFont)
                                        .italic(surfaceItalic)
                                } else {
                                    Text(verbatim: segment.surface)
                                        .font(surfaceFont)
                                        .italic(surfaceItalic)
                                    Text(verbatim: note)
                                        .font(annotationFont)
                                        .foregroundStyle(annotationColor)
                                        .lineLimit(1)
                                }
                            }
                        } else {
                            plainSegment(segment)
                        }
                    }
                }
            } else {
                // Nothing annotatable: plain text keeps the slot filled.
                Text(verbatim: text)
                    .font(surfaceFont)
                    .italic(surfaceItalic)
            }
        }
    }

    private func reading(for segment: ReadingSegment) -> String? {
        annotation == .furigana ? segment.furigana : segment.romaji
    }

    /// Furigana sits above the surface, and the flow layout top-aligns its
    /// children — so an unannotated run must reserve an invisible annotation
    /// line to keep its surface on the same baseline as annotated words.
    /// (Romaji sits below the surface, where top alignment already works.)
    @ViewBuilder
    private func plainSegment(_ segment: ReadingSegment) -> some View {
        if annotation == .furigana {
            VStack(spacing: 0) {
                Text(verbatim: " ")
                    .font(annotationFont)
                    .lineLimit(1)
                Text(verbatim: segment.surface)
                    .font(surfaceFont)
                    .italic(surfaceItalic)
            }
        } else {
            Text(verbatim: segment.surface)
                .font(surfaceFont)
                .italic(surfaceItalic)
        }
    }
}
