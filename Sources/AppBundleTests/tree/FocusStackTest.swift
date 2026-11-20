@testable import AppBundle
import Common
import Foundation
import Testing

@Suite("FocusStack")
struct FocusStackTest {
    func stack(_ ids: UInt32...) -> FocusStack {
        var stack = FocusStack()
        for id in ids { stack.push(id) }
        return stack
    }

    func previous(
        _ stack: inout FocusStack,
        current: UInt32?,
        alive: Set<UInt32>? = nil,
        focusable: Set<UInt32>? = nil,
    ) -> UInt32? {
        stack.previous(
            before: current,
            exists: { alive?.contains($0) ?? true },
            canFocus: { focusable?.contains($0) ?? true },
        )
    }

    @Test func thePreviousWindowIsTheOneFocusedBeforeTheCurrentOne() {
        var stack = stack(1, 2, 3)
        #expect(previous(&stack, current: 3) == 2)
    }

    @Test func goingBackAndForthTogglesBetweenTheTwoMostRecent() {
        var stack = stack(1, 2, 3)
        let back = previous(&stack, current: 3)
        stack.push(back!)
        #expect(previous(&stack, current: 2) == 3)
    }

    @Test func pushingAgainMovesAWindowToTheTop() {
        let stack = stack(1, 2, 3, 1)
        #expect(stack.windowIds == [2, 3, 1])
    }

    // A close moves nothing by itself; the closed window just drops out.
    @Test func aClosedWindowDropsOut() {
        var stack = stack(1, 2, 3)
        stack.remove(3)
        #expect(stack.windowIds == [1, 2])
    }

    // After a close macOS focuses some window (here 9); going back skips it
    // and lands on the window focused before the closed one.
    @Test func afterACloseGoingBackReachesTheWindowBeforeIt() {
        var stack = stack(1, 2, 3)
        stack.push(9) // macOS's pick
        stack.remove(3)
        #expect(previous(&stack, current: 9) == 2)
    }

    @Test func windowsThatNoLongerExistAreSkippedAndForgotten() {
        var stack = stack(1, 2, 3, 4)
        #expect(previous(&stack, current: 4, alive: [1, 4]) == 1)
        #expect(stack.windowIds == [1, 4])
    }

    @Test func aMinimizedWindowIsSkippedButRemembered() {
        var stack = stack(1, 2, 3)
        #expect(previous(&stack, current: 3, focusable: [1, 3]) == 1)
        #expect(stack.windowIds == [1, 2, 3])
    }

    @Test func noOtherWindowMeansNothingToGoBackTo() {
        var stack = stack(1)
        #expect(previous(&stack, current: 1) == nil)
    }

    @Test func theStackIsBounded() {
        var stack = FocusStack()
        for id in 0 ..< UInt32(FocusStack.limit + 10) { stack.push(id) }
        #expect(stack.windowIds.count == FocusStack.limit)
        #expect(stack.windowIds.first == 10)
    }
}

@MainActor
@Suite("focus-back-and-forth", .serialized)
struct FocusBackAndForthTest {
    init() { setUpWorkspacesForTests() }

    func run() async throws -> CmdResult {
        try await FocusBackAndForthCommand(args: FocusBackAndForthCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
    }

    @Test func goesBackAcrossWorkspacesAndForthAgain() async throws {
        let one = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        let two = TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)
        #expect(one.focusWindow())
        #expect(two.focusWindow())

        _ = try await run()
        #expect(focus.windowOrNil?.windowId == 1)
        #expect(focus.workspace.name == "a")

        _ = try await run()
        #expect(focus.windowOrNil?.windowId == 2)
    }

    @Test func afterTheFocusedWindowClosesItReachesTheOneBeforeIt() async throws {
        let one = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        let two = TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)
        let three = TestWindow.new(id: 3, parent: Workspace.get(byName: "b").rootTilingContainer)
        #expect(three.focusWindow())
        #expect(one.focusWindow())
        #expect(two.focusWindow())

        two.unbindFromParent() // closed
        focusStack.remove(2)
        #expect(three.focusWindow()) // where macOS and the workspace put focus
        #expect(focus.windowOrNil?.windowId == 3)

        _ = try await run()
        #expect(focus.windowOrNil?.windowId == 1)
    }

    @Test func withNoOtherWindowItFails() async throws {
        #expect(TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer).focusWindow())
        let result = try await run()
        #expect(result.exitCode.rawValue != 0)
        #expect(result.stderr == ["No other recently focused window"])
    }
}
