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
        assertEquals(b.stackingLayout.placements[1], .single(lane: 0, slot: 0))
        assertEquals(b.stackingLayout.placements[2], .single(lane: 0, slot: 1))
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
        assertEquals(b.stackingLayout.placements[1], .single(lane: 0, slot: 0))
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
