@testable import AppBundle
import Common
import XCTest

/// A window joining another column meets it halfway; moving on gives the
/// column its old width back; otherwise the halfway width is final.
@MainActor
final class JoinedColumnTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// Column 0: window 1 (0.6). Column 1: window 2 (0.2). Column 2: window 3 (0.2).
    private func threeColumns() -> Workspace {
        let a = Workspace.get(byName: "a")
        for id: UInt32 in 1 ... 3 { TestWindow.new(id: id, parent: a.rootTilingContainer) }
        let layout = a.stackingLayout
        for (lane, id) in [1, 2, 3].enumerated() { layout.place(WindowId(id), at: .soleSlot(lane: lane)) }
        layout.setLaneWeights([0.6, 0.2, 0.2] + Array(repeating: 0.4, count: layout.shape.lanes - 3))
        return a
    }

    private func width(of id: WindowId, in ws: Workspace) -> CGFloat {
        renderedColumnFraction(of: id, in: ws) ?? -1
    }

    private func drag(_ id: WindowId, into mate: WindowId, in ws: Workspace) {
        let lane = ws.stackingLayout.placements[mate]?.lane0 ?? -1
        commitStackingDrop(StackingDragSession(windowId: id, workspace: ws, targetWorkspace: ws, hoverCell: (lane: lane, slot: 0)))
    }

    func testTheJoinedColumnMeetsTheWindowHalfway() {
        let a = threeColumns()
        drag(1, into: 2, in: a)
        assertEquals(a.stackingLayout.placements[1]?.lane0, a.stackingLayout.placements[2]?.lane0)
        // (0.2 + 0.6) / 2 of the axis, beside window 3's 0.2.
        XCTAssertEqual(width(of: 2, in: a) / (width(of: 2, in: a) + width(of: 3, in: a)), 0.4 / 0.6, accuracy: 0.02)
    }

    func testMovingOnRestoresTheColumnItLeft() {
        let a = threeColumns()
        drag(1, into: 2, in: a)
        let before3 = width(of: 3, in: a)
        drag(1, into: 3, in: a)
        // Column of 2 is back to its width, column of 3 meets window 1 halfway.
        XCTAssertNotEqual(a.stackingLayout.placements[1]?.lane0, a.stackingLayout.placements[2]?.lane0)
        assertEquals(a.stackingLayout.placements[1]?.lane0, a.stackingLayout.placements[3]?.lane0)
        let w2 = width(of: 2, in: a), w3 = width(of: 3, in: a)
        XCTAssertEqual(w3 / (w2 + w3), 0.4 / 0.6, accuracy: 0.02)
        XCTAssertGreaterThan(w3, before3)
    }

    func testAnotherWindowsMoveMakesTheHalfwayWidthFinal() {
        let a = threeColumns()
        drag(1, into: 2, in: a)
        let halfway = a.stackingLayout.laneWeight(lane: a.stackingLayout.placements[2]?.lane0 ?? -1)
        _ = startMove(of: Window.get(byId: 3)!, renderedAt: nil)
        drag(1, into: 3, in: a)
        // Window 1's next move no longer restores column 2.
        XCTAssertEqual(a.stackingLayout.laneWeight(lane: a.stackingLayout.placements[2]?.lane0 ?? -1), halfway, accuracy: 1e-9)
    }

    func testMovingToAnotherWorkspaceRestoresTheColumnItLeft() {
        let a = threeColumns()
        drag(1, into: 2, in: a)
        let b = Workspace.get(byName: "b")
        _ = moveWindowToWorkspace(Window.get(byId: 1)!, b, CmdIo(stdin: .emptyStdin), focusFollowsWindow: false, failIfNoop: false)
        // Columns 2 and 3 are back to 0.2 each.
        XCTAssertEqual(width(of: 2, in: a), width(of: 3, in: a), accuracy: 0.01)
        XCTAssertNil(joinedColumnMemory.entry)
    }

    func testHalfway() {
        XCTAssertEqual(halfwayWidth(column: 0.2, window: 0.6), 0.4, accuracy: 1e-12)
    }
}
