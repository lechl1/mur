@testable import AppBundle
import Common
import Testing
import AppKit

@Suite("GridResize")
struct GridResizeTest {
    private let available = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 600)

    @Test func dragRightEdgeOnePixelOverHalfwayExtendsByOneCol() {
        // Layout: 3x3, all three columns in use → visible cells width=300.
        let layout = GridLayout(shape: .defaultLayout)
        layout.place(1, at: .column(0, in: .defaultLayout)) // window under test
        layout.place(2, at: .column(1, in: .defaultLayout))
        layout.place(3, at: .column(2, in: .defaultLayout))

        // Window 1's snapped rect is (0,0,300,600). User dragged right edge
        // to x=460 (past the col0/col1 boundary at 300, well past gutter).
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 600)
        let cur = Rect(topLeftX: 0, topLeftY: 0, width: 460, height: 600)

        let snapped = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: available, innerGap: 0,
        ))
        // Right edge should snap to the right edge of visible cell 1
        // (absolute col 1) → new span is col0=0, col1=1.
        #expect(snapped == TileSpan(col0: 0, row0: 0, col1: 1, row1: 2))
    }

    @Test func dragLeftEdgeRightShrinksLeftSide() {
        let layout = GridLayout(shape: .defaultLayout)
        layout.place(1, at: TileSpan(col0: 0, row0: 0, col1: 2, row1: 2)) // full
        // Only window 1 → usedCols = {0,1,2}, visible cells width=300.
        // User drags left edge from x=0 to x=310 (just past col 0/col 1
        // boundary at 300).
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 600)
        let cur = Rect(topLeftX: 310, topLeftY: 0, width: 590, height: 600)

        let snapped = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: available, innerGap: 0,
        ))
        #expect(snapped == TileSpan(col0: 1, row0: 0, col1: 2, row1: 2))
    }

    @Test func subPixelJitterDoesNotChangeSpan() {
        let layout = GridLayout(shape: .defaultLayout)
        layout.place(1, at: .column(1, in: .defaultLayout))
        let last = Rect(topLeftX: 300, topLeftY: 0, width: 300, height: 600)
        let cur = Rect(topLeftX: 300.3, topLeftY: 0.2, width: 299.6, height: 599.8)
        let snapped = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: available, innerGap: 0,
        ))
        // No edge moved beyond epsilon=1.0 → returns nil (no change).
        #expect(snapped == nil)
    }

    @Test func collapseAwareSnapMapsThroughVisibleCells() {
        // Used cols = {0, 2} → visible cells of width 450 each.
        let layout = GridLayout(shape: .defaultLayout)
        layout.place(1, at: .column(0, in: .defaultLayout))
        layout.place(2, at: .column(2, in: .defaultLayout))
        // User drags window 1's right edge from x=450 to x=700 (past the
        // visible boundary at 450, into visible cell 1).
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 450, height: 600)
        let cur = Rect(topLeftX: 0, topLeftY: 0, width: 700, height: 600)
        let snapped = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: available, innerGap: 0,
        ))
        // Visible boundary index 2 (past-the-end) → absolute col usedCols[1]=2.
        // So window 1 grows to col0=0, col1=2.
        #expect(snapped == TileSpan(col0: 0, row0: 0, col1: 2, row1: 2))
    }

    @Test func detectEdgesIdentifiesAllFour() {
        let last = Rect(topLeftX: 100, topLeftY: 100, width: 200, height: 200)
        // Each edge moved by 10px outward.
        let cur = Rect(topLeftX: 90, topLeftY: 90, width: 220, height: 220)
        let edges = GridResize.detectEdges(.init(
            layout: GridLayout(), windowId: 0,
            lastAppliedRect: last, currentRect: cur,
            available: Rect(topLeftX: 0, topLeftY: 0, width: 1, height: 1),
            innerGap: 0,
        ))
        #expect(edges.contains(.left))
        #expect(edges.contains(.right))
        #expect(edges.contains(.top))
        #expect(edges.contains(.bottom))
    }
}
