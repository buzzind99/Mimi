import CoreGraphics
@testable import Mimi
import Testing

@Suite("Ruby flow packing")
struct RubyFlowPackingTests {

    // MARK: - Helpers

    private func pack(
        _ sizes: [CGSize], wraps: [Bool], width: CGFloat,
        spacing: CGFloat = 4, lineSpacing: CGFloat = 1
    ) -> RubyFlowPacking {
        RubyFlowPacking.pack(
            sizes: sizes, wraps: wraps, width: width,
            spacing: spacing, lineSpacing: lineSpacing
        )
    }

    // MARK: - pack

    @Test("places single-line children left-to-right, wrapping at the width")
    func rowPacking() {
        let sizes = [CGSize(width: 100, height: 30), CGSize(width: 50, height: 30), CGSize(width: 80, height: 30)]

        let result = pack(sizes, wraps: [false, false, false], width: 200)

        #expect(result.placements == [CGPoint(x: 0, y: 0), CGPoint(x: 104, y: 0), CGPoint(x: 0, y: 31)])
        #expect(result.totalSize == CGSize(width: 200, height: 61))
    }

    @Test("starts the next child on a fresh line below an internally wrapping child")
    func wrappingChildForcesFreshRow() {
        let sizes = [CGSize(width: 1300, height: 40), CGSize(width: 60, height: 40)]

        let result = pack(sizes, wraps: [true, false], width: 1465)

        #expect(result.placements == [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 41)])
        #expect(result.totalSize == CGSize(width: 1465, height: 81))
    }

    @Test("wrapping child shares its first row with preceding children")
    func wrappingChildSharesFirstRow() {
        let sizes = [CGSize(width: 100, height: 30), CGSize(width: 1300, height: 60), CGSize(width: 50, height: 30)]

        let result = pack(sizes, wraps: [false, true, false], width: 1465)

        #expect(result.placements == [CGPoint(x: 0, y: 0), CGPoint(x: 104, y: 0), CGPoint(x: 0, y: 61)])
        #expect(result.totalSize == CGSize(width: 1465, height: 91))
    }

    @Test("consecutive wrapping children each get their own row")
    func consecutiveWrappingChildren() {
        let sizes = [CGSize(width: 1300, height: 40), CGSize(width: 1300, height: 50)]

        let result = pack(sizes, wraps: [true, true], width: 1465)

        #expect(result.placements == [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 41)])
        #expect(result.totalSize == CGSize(width: 1465, height: 91))
    }

    @Test("adds no trailing line spacing when a wrapping child ends the content")
    func noTrailingGapAfterWrappingChild() {
        let sizes = [CGSize(width: 1300, height: 40)]

        let result = pack(sizes, wraps: [true], width: 1465)

        #expect(result.placements == [CGPoint(x: 0, y: 0)])
        #expect(result.totalSize == CGSize(width: 1465, height: 40))
    }

    @Test("lays out a single row at infinite width")
    func infiniteWidthSingleRow() {
        let sizes = [CGSize(width: 100, height: 30), CGSize(width: 50, height: 30)]

        let result = pack(sizes, wraps: [false, false], width: .infinity)

        #expect(result.placements == [CGPoint(x: 0, y: 0), CGPoint(x: 104, y: 0)])
        #expect(result.totalSize == CGSize(width: 154, height: 30))
    }
}
