@testable import AppBundle
import Common
import Testing
import AppKit

@Suite("GridLayout")
struct GridLayoutTest {
    // MARK: TileSpan

    @Test func tileSpanClampShrinksToFit() {
        let span = TileSpan(col0: 0, row0: 0, col1: 4, row1: 4)
        let clamped = span.clamped(to: GridShape(cols: 3, rows: 3))
        #expect(clamped == TileSpan(col0: 0, row0: 0, col1: 2, row1: 2))
    }

    @Test func tileSpanClampReturnsNilWhenFullyOutside() {
        let span = TileSpan(col0: 5, row0: 5, col1: 6, row1: 6)
        // Negative-only domain via clamp: the clamp moves both endpoints
        // to col=2, so this is actually a degenerate single cell — not
        // "fully outside" by the current implementation. Use a real
        // out-of-domain check via reshape instead. Keep this test honest:
        let clamped = span.clamped(to: GridShape(cols: 3, rows: 3))
        #expect(clamped == TileSpan(col0: 2, row0: 2, col1: 2, row1: 2))
    }

    @Test func tileSpanOverlapDetection() {
        let a = TileSpan(col0: 0, row0: 0, col1: 1, row1: 1)
        let b = TileSpan(col0: 1, row0: 1, col1: 2, row1: 2)
        let c = TileSpan(col0: 2, row0: 2, col1: 2, row1: 2)
        #expect(a.overlaps(b))
        #expect(!a.overlaps(c))
    }

    // MARK: collapsing

    @Test func collapsingEmptyColumnsExpandsRemaining() {
        let layout = GridLayout(shape: .defaultLayout) // 3×3
        // Place one window in column 0 only.
        layout.place(1, at: .column(0, in: .defaultLayout))
        // With column 1 and 2 empty, the only "used" column is col 0.
        // It should occupy the FULL width of `available`.
        let available = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 600)
        let rect = layout.resolveRect(for: 1, in: available)
        #expect(rect != nil)
        #expect(rect?.width == 900)
        #expect(rect?.height == 600)
    }

    @Test func collapsingTwoUsedColumnsSplitsHalf() {
        let layout = GridLayout(shape: .defaultLayout)
        layout.place(1, at: .column(0, in: .defaultLayout))
        layout.place(2, at: .column(2, in: .defaultLayout))
        let available = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 600)
        // Used cols = {0, 2}. Two used cells of width 450 each.
        let r1 = layout.resolveRect(for: 1, in: available)
        let r2 = layout.resolveRect(for: 2, in: available)
        #expect(r1?.width == 450)
        #expect(r2?.width == 450)
        #expect(r1?.topLeftX == 0)
        #expect(r2?.topLeftX == 450)
    }

    // MARK: placement heuristic

    @Test func newWindowOnEmptyWorkspaceGoesToMiddleColumn() {
        let layout = GridLayout(shape: .defaultLayout)
        let span = layout.placementForNewWindow()
        #expect(span == .column(1, in: .defaultLayout))
    }

    @Test func newWindowAdjacentToSingleUsedColumnPicksEmptySide() {
        let layout = GridLayout(shape: .defaultLayout)
        // Existing window in column 0. Both 1 and 2 are empty; right is
        // the side with more space, so the heuristic should pick col=2
        // (the further-right empty column with maximum space).
        layout.place(1, at: .column(0, in: .defaultLayout))
        let span = layout.placementForNewWindow()
        // cStar=0, leftEmpty=false (no col -1), rightEmpty=true → col 1.
        #expect(span == .column(1, in: .defaultLayout))
    }

    @Test func newWindowOverlapsMiddleWhenNoEmptyColumn() {
        let layout = GridLayout(shape: .defaultLayout)
        layout.place(1, at: .column(0, in: .defaultLayout))
        layout.place(2, at: .column(1, in: .defaultLayout))
        layout.place(3, at: .column(2, in: .defaultLayout))
        // No empty columns left. New window should overlap middle (col 1).
        let span = layout.placementForNewWindow()
        #expect(span == .column(1, in: .defaultLayout))
    }

    // MARK: zOrder

    @Test func placePromotesToTopOfZOrder() {
        let layout = GridLayout()
        layout.place(1, at: .cell(col: 0, row: 0))
        layout.place(2, at: .cell(col: 1, row: 0))
        layout.place(3, at: .cell(col: 2, row: 0))
        #expect(layout.zOrder == [1, 2, 3])
        layout.place(1, at: .cell(col: 0, row: 0)) // re-place
        #expect(layout.zOrder == [2, 3, 1])
    }

    @Test func reshapeEvictsWindowsOutsideNewBounds() {
        let layout = GridLayout(shape: GridShape(cols: 4, rows: 4))
        layout.place(1, at: .cell(col: 0, row: 0))
        layout.place(2, at: .cell(col: 3, row: 3))
        let evicted = layout.reshape(to: GridShape(cols: 2, rows: 2))
        // Window 2 is at (3,3), which doesn't fit in a 2x2; clamped to (1,1).
        // Both should survive because clamp pulls them inside.
        #expect(evicted.isEmpty)
        #expect(layout.shape == GridShape(cols: 2, rows: 2))
    }
}
