@testable import AppBundle
import Common
import XCTest

@MainActor
final class ExplicitFloatingTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testAFloatingWindowTheUserDidNotFloatIsTiled() {
        // How the inherited tree code leaves one: a dialog-looking window at
        // registration, one back from minimize, the closed-windows cache.
        let a = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 1, parent: a)

        tileWindowsNotExplicitlyFloating()

        XCTAssertFalse(window.isFloating)
        XCTAssertNotNil(a.stackingLayout.placements[1])
    }

    func testAWindowTheUserFloatedStaysFloating() {
        let a = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 1, parent: a)
        explicitlyFloatingWindowIds.insert(1)

        tileWindowsNotExplicitlyFloating()

        XCTAssertTrue(window.isFloating)
        XCTAssertNil(a.stackingLayout.placements[1])
    }

    func testLayoutFloatingIsRecordedAndLeavesTheGrid() async throws {
        // (`layout tiling` reads the AX size, which TestWindow doesn't have.)
        let a = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 1, parent: a.rootTilingContainer)
        _ = window.focusWindow()
        a.stackingLayout.place(1, at: .soleSlot(lane: 0))

        try await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.floating])).run(.defaultEnv, .emptyStdin)

        XCTAssertTrue(window.isFloating)
        XCTAssertTrue(explicitlyFloatingWindowIds.contains(1))
        XCTAssertNil(a.stackingLayout.placements[1])
        tileWindowsNotExplicitlyFloating()
        XCTAssertTrue(window.isFloating)
    }
}
