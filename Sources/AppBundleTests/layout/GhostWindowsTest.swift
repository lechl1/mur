@testable import AppBundle
import Common
import XCTest

@MainActor
final class GhostWindowsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testAGhostLeavesItsTileAndComesBackToIt() {
        // Dimify's closed settings window: transparent, 0×0, in the middle
        // column of three.
        let a = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: a.rootTilingContainer)
        let ghost = TestWindow.new(id: 2, parent: a.rootTilingContainer)
        TestWindow.new(id: 3, parent: a.rootTilingContainer)
        a.stackingLayout.place(1, at: .soleSlot(lane: 0))
        a.stackingLayout.place(2, at: .soleSlot(lane: 1))
        a.stackingLayout.place(3, at: .soleSlot(lane: 2))

        applyGhostWindows([2])
        tileWindowsNotExplicitlyFloating()

        XCTAssertNil(a.stackingLayout.placements[2])
        assertEquals(a.stackingLayout.usedLanes.count, 2)
        XCTAssertTrue(ghost.isFloating)
        XCTAssertFalse(explicitlyFloatingWindowIds.contains(2))

        // Drawn again: tiled back between its old neighbours.
        applyGhostWindows([])
        tileWindowsNotExplicitlyFloating()

        XCTAssertFalse(ghost.isFloating)
        let lanes = [1, 2, 3].map { a.stackingLayout.placements[$0]?.lane0 ?? -1 }
        XCTAssertTrue(lanes[0] < lanes[1] && lanes[1] < lanes[2], "\(lanes)")
    }

    func testAGhostTheUserFloatedIsLeftAlone() {
        let a = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 1, parent: a)
        explicitlyFloatingWindowIds.insert(1)

        applyGhostWindows([1])
        applyGhostWindows([])
        tileWindowsNotExplicitlyFloating()

        XCTAssertTrue(window.isFloating)
        XCTAssertNil(a.stackingLayout.placements[1])
    }

    func testTheRestoreLeavesAGhostOutOfTheGrid() {
        // The restore re-tiles every window it handles: a ghost it handled
        // took a row back, and the window beside it filled half its column.
        let a = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: a.rootTilingContainer)
        TestWindow.new(id: 2, parent: a.rootTilingContainer)
        a.stackingLayout.place(1, at: .single(lane: 0, slot: 0))
        a.stackingLayout.place(2, at: .single(lane: 0, slot: 1))
        applyGhostWindows([2])

        assertEquals(windowsToRestore([1, 2]), [1])
    }

    func testAWindowBoundIntoAGarbageCollectedWorkspaceIsTakenBack() {
        // The restore picked workspace "10" (not persistent, still empty),
        // awaited a title, a refresh garbage-collected "10", and the window
        // was bound into that dead workspace: out of mur's control for good.
        let dead = Workspace.get(byName: "10")
        Workspace.garbageCollectUnusedWorkspaces()
        let window = TestWindow.new(id: 1, parent: dead.rootTilingContainer)

        reclaimOrphanedWindows([window])

        let live = Workspace.get(byName: "10")
        XCTAssertFalse(live === dead)
        XCTAssertTrue(window.nodeWorkspace === live)
        XCTAssertNotNil(live.stackingLayout.placements[1])
    }

    func testAWindowWithNoParentIsTakenBackOnTheFocusedWorkspace() {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        window.unbindFromParent()

        reclaimOrphanedWindows([window])

        XCTAssertTrue(window.nodeWorkspace === focus.workspace)
    }

    func testWhatCountsAsAGhost() {
        XCTAssertTrue(isGhostFrame(alpha: 0, size: CGSize(width: 800, height: 600)))
        XCTAssertTrue(isGhostFrame(alpha: 1, size: .zero))
        XCTAssertTrue(isGhostFrame(alpha: 1, size: CGSize(width: 800, height: 1)))
        XCTAssertFalse(isGhostFrame(alpha: 1, size: CGSize(width: 800, height: 600)))
        // A dimmed (translucent) window is still drawn.
        XCTAssertFalse(isGhostFrame(alpha: 0.5, size: CGSize(width: 800, height: 600)))
    }
}
