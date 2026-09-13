import SwiftUI

/// Pure placement pass for `FlowLayout`: packs children left-to-right,
/// wrapping to a new line when the next child would exceed the available
/// width. Children flagged in `wraps` re-wrap internally (they were
/// re-measured to fit the line, so they span multiple visual lines), and a
/// row always closes after one — the next child starts on a fresh line
/// below it, never beside its lower lines.
struct RubyFlowPacking {
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

/// The `Layout` conformance wrapping `RubyFlowPacking`: caches ideal child
/// sizes keyed by `fingerprint`, re-measures children wider than the line so
/// they wrap internally, and places per the packer's placements. Child sizes
/// are measured once per content change and line breaks are packed per
/// proposal width, so the repeated layout passes List's virtualized rows
/// trigger (scroll materialization, insertion springs, re-anchor chases)
/// don't re-measure every child each time. The fingerprint also guards row
/// recycling: a reused layout instance re-measures when its content changes.
struct FlowLayout: Layout {
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
        var packedSpacing: CGFloat = 0
        var packedLineSpacing: CGFloat = 0
        var placements: [CGPoint] = []
        var totalSize = CGSize.zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // The fingerprint fully determines the children's content (text,
        // fonts, annotation and cursor mode, reservation), so a match with a
        // steady count is enough to reuse the cached sizes — no need to
        // re-measure the first child on every pass.
        let unchanged = cache.fingerprint == fingerprint
            && cache.sizes.count == subviews.count
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
        guard cache.packedWidth != width
            || cache.packedSpacing != spacing
            || cache.packedLineSpacing != lineSpacing
        else { return }
        cache.packedWidth = width
        cache.packedSpacing = spacing
        cache.packedLineSpacing = lineSpacing
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
