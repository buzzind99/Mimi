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

/// Ruby-style romaji: each kana/kanji word renders with its romaji directly
/// beneath it, wrapping like normal text. Runs without a distinct reading
/// (punctuation, Latin, digits) render inline as plain text, so their
/// surfaces stay top-aligned with annotated words on the same line.
struct RomajiRubyView: View {
    let text: String
    var surfaceFont: Font
    var romajiFont: Font
    var romajiColor: Color
    var surfaceItalic = false

    var body: some View {
        if let segments = RomajiAnnotator.segments(for: text),
           segments.contains(where: { $0.romaji != nil && $0.romaji != $0.surface })
        {
            FlowLayout(spacing: 4, lineSpacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    if let romaji = segment.romaji, romaji != segment.surface {
                        VStack(spacing: 0) {
                            Text(verbatim: segment.surface)
                                .font(surfaceFont)
                                .italic(surfaceItalic)
                            Text(verbatim: romaji)
                                .font(romajiFont)
                                .foregroundStyle(romajiColor)
                                .lineLimit(1)
                        }
                    } else {
                        Text(verbatim: segment.surface)
                            .font(surfaceFont)
                            .italic(surfaceItalic)
                    }
                }
            }
        }
    }
}
