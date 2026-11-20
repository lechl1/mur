@testable import AppBundle
import Common
import XCTest

@MainActor
final class StackingDragDropTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testDropOnAnotherMonitorMovesTheWindowThere() {
        // A window dragged onto the other monitor used to be hit-tested
        // against its own grid and snap back.
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        _ = TestWindow.new(id: 1, parent: a.rootTilingContainer).focusWindow()
        TestWindow.new(id: 2, parent: b.rootTilingContainer)
        a.stackingLayout.place(1, at: .soleSlot(lane: 0))
        b.stackingLayout.place(2, at: .soleSlot(lane: 0))

        commitStackingDrop(StackingDragSession(windowId: 1, workspace: a, targetWorkspace: b, hoverCell: (lane: 0, slot: 0)))

        assertEquals(Window.get(byId: 1)?.nodeWorkspace, b)
        XCTAssertNil(a.stackingLayout.placements[1])
        // A column of its own (no drop point: appended), not a row of 2's.
        assertEquals(b.stackingLayout.placements[2], .soleSlot(lane: 0))
        assertEquals(b.stackingLayout.placements[1], .soleSlot(lane: 1))
    }

    func testDropOnAnotherMonitorKeepsTheWindowsWidthAndShrinksTheOthers() {
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        _ = TestWindow.new(id: 1, parent: a.rootTilingContainer).focusWindow()
        TestWindow.new(id: 2, parent: b.rootTilingContainer)
        TestWindow.new(id: 3, parent: b.rootTilingContainer)
        a.stackingLayout.place(1, at: .soleSlot(lane: 0))
        a.stackingLayout.setLaneAbsoluteWidth(0.6, lane: 0)
        b.stackingLayout.place(2, at: .soleSlot(lane: 0))
        b.stackingLayout.place(3, at: .soleSlot(lane: 1))
        b.stackingLayout.setLaneWeights([0.5, 0.5] + Array(repeating: 0.4, count: b.stackingLayout.shape.lanes - 2))
        let avail = b.workspaceMonitor.visibleRectPaddedByOuterGaps

        // Dropped on the left edge: it opens leftmost.
        commitStackingDrop(StackingDragSession(
            windowId: 1, workspace: a, targetWorkspace: b, hoverCell: (lane: 0, slot: 0),
            dropPoint: CGPoint(x: avail.topLeftX + 1, y: avail.center.y),
        ))

        let layout = b.stackingLayout
        assertEquals(layout.placements[1], .soleSlot(lane: 0))
        XCTAssertEqual(layout.laneWeight(lane: 0), 0.6, accuracy: 1e-9)
        // The others shrink in proportion to fill exactly what is left.
        XCTAssertEqual(layout.laneWeight(lane: 1), 0.2, accuracy: 1e-9)
        XCTAssertEqual(layout.laneWeight(lane: 2), 0.2, accuracy: 1e-9)
    }

    func testDropIntoAnotherColumnKeepsTheRowHeightUpToAnEqualShare() {
        let a = Workspace.get(byName: "a")
        for id: UInt32 in 1 ... 6 { TestWindow.new(id: id, parent: a.rootTilingContainer) }
        let layout = a.stackingLayout
        // Column 0: four equal rows (window 1 is a quarter high).
        for (s, id) in [1, 2, 3, 4].enumerated() { layout.place(WindowId(id), at: .single(lane: 0, slot: s)) }
        // Column 1: two rows.
        layout.place(5, at: .single(lane: 1, slot: 0))
        layout.place(6, at: .single(lane: 1, slot: 1))

        commitStackingDrop(StackingDragSession(windowId: 1, workspace: a, targetWorkspace: a, hoverCell: (lane: 1, slot: 0)))

        let span = layout.placements[1]
        assertEquals(span?.lane0, layout.placements[5]?.lane0)
        let lane = span?.lane0 ?? -1
        let weights = (0 ..< 3).map { layout.slotWeight(lane: lane, slot: $0) }
        // A quarter of the column, as before — not the equal third.
        XCTAssertEqual(weights[span?.slot0 ?? 0] / weights.reduce(0, +), 0.25, accuracy: 0.01)
    }

    func testDropOnTheSameMonitorStaysInItsWorkspace() {
        let a = Workspace.get(byName: "a")
        _ = TestWindow.new(id: 1, parent: a.rootTilingContainer).focusWindow()
        TestWindow.new(id: 2, parent: a.rootTilingContainer)
        a.stackingLayout.place(1, at: .soleSlot(lane: 0))
        a.stackingLayout.place(2, at: .soleSlot(lane: 1))

        commitStackingDrop(StackingDragSession(windowId: 1, workspace: a, targetWorkspace: a, hoverCell: (lane: 1, slot: 1)))

        assertEquals(Window.get(byId: 1)?.nodeWorkspace, a)
        // Lane 0 emptied and was compacted away: both now share one column.
        assertEquals(a.stackingLayout.placements[1]?.lane0, a.stackingLayout.placements[2]?.lane0)
    }

    func testAWindowOutsideTheGridTilesOnTheMonitorItIsDroppedOn() {
        // In the tree but without a cell: the old drag only rebound it.
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        _ = TestWindow.new(id: 1, parent: a.rootTilingContainer).focusWindow()
        TestWindow.new(id: 2, parent: b.rootTilingContainer)
        b.stackingLayout.place(2, at: .soleSlot(lane: 0))

        commitStackingDrop(StackingDragSession(windowId: 1, workspace: a, targetWorkspace: b, hoverCell: (lane: 0, slot: 0)))

        assertEquals(Window.get(byId: 1)?.nodeWorkspace, b)
        assertEquals(b.stackingLayout.placements[1], .soleSlot(lane: 1))
    }

    func testAWindowTheUserFloatedStaysFloating() {
        let a = Workspace.get(byName: "a")
        let b = Workspace.get(byName: "b")
        _ = TestWindow.new(id: 1, parent: a).focusWindow()
        explicitlyFloatingWindowIds.insert(1)
        TestWindow.new(id: 2, parent: b.rootTilingContainer)
        b.stackingLayout.place(2, at: .soleSlot(lane: 0))

        commitStackingDrop(StackingDragSession(windowId: 1, workspace: a, targetWorkspace: b, hoverCell: (lane: 0, slot: 0)))

        assertEquals(Window.get(byId: 1)?.nodeWorkspace, b)
        XCTAssertTrue(Window.get(byId: 1)?.isFloating ?? false)
        XCTAssertNil(b.stackingLayout.placements[1])
    }
}
