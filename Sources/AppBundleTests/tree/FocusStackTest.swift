@testable import AppBundle
import Foundation
import Testing

@Suite("FocusStack")
struct FocusStackTest {
    let start = Date(timeIntervalSinceReferenceDate: 1000)

    func stack(_ ids: UInt32...) -> FocusStack {
        var stack = FocusStack()
        for id in ids { stack.push(id) }
        return stack
    }

    func pop(_ stack: inout FocusStack, alive: Set<UInt32>? = nil, focusable: Set<UInt32>? = nil) -> UInt32? {
        stack.takePopTarget(
            exists: { alive?.contains($0) ?? true },
            canFocus: { focusable?.contains($0) ?? true },
        )
    }

    @Test func closingTheFocusedWindowPopsToThePreviousOne() {
        var stack = stack(1, 2, 3)
        stack.remove(3, at: start)
        #expect(pop(&stack) == 2)
    }

    @Test func pushingAgainMovesAWindowToTheTop() {
        var stack = stack(1, 2, 3, 1)
        #expect(stack.windowIds == [2, 3, 1])
        stack.remove(1, at: start)
        #expect(pop(&stack) == 3)
    }

    @Test func closingABackgroundWindowKeepsFocus() {
        var stack = stack(1, 2, 3)
        stack.remove(2, at: start)
        #expect(pop(&stack) == nil)
        #expect(stack.windowIds == [1, 3])
    }

    // macOS focuses the app's next window (or the next app) before mur hears
    // of the close: that pick is undone.
    @Test func macOsFallbackAfterACloseIsUndone() {
        var stack = stack(1, 2, 3) // 3 focused, 2 before it, 1 long ago
        stack.noteNativeSwitch(from: 3, to: 1, at: start)
        stack.push(1) // mur followed macOS
        stack.remove(3, at: start.addingTimeInterval(0.3))
        #expect(pop(&stack) == 2)
        #expect(stack.windowIds == [1, 2])
    }

    @Test func macOsPickingThePreviousWindowItselfStaysThere() {
        var stack = stack(1, 2, 3)
        stack.noteNativeSwitch(from: 3, to: 2, at: start)
        stack.push(2)
        stack.remove(3, at: start.addingTimeInterval(0.3))
        #expect(pop(&stack) == 2)
    }

    @Test func anAppQuittingWithNoWindowLeftPopsToo() {
        var stack = stack(1, 2)
        stack.noteNativeSwitch(from: 2, to: nil, at: start)
        stack.remove(2, at: start.addingTimeInterval(0.1))
        #expect(pop(&stack) == 1)
    }

    @Test func aDeliberateSwitchLongBeforeTheCloseIsKept() {
        var stack = stack(1, 2, 3)
        stack.noteNativeSwitch(from: 3, to: 1, at: start)
        stack.push(1)
        stack.remove(3, at: start.addingTimeInterval(FocusStack.fallbackWindow + 1))
        #expect(pop(&stack) == nil)
        #expect(stack.top == 1)
    }

    // A splash or dialog closing as its app's main window opens: the new
    // window keeps focus.
    @Test func aWindowThatJustOpenedKeepsTheFocusItWasGiven() {
        var stack = stack(1, 2) // 2 is the splash
        stack.noteRegistered(3, at: start)
        stack.noteNativeSwitch(from: 2, to: 3, at: start.addingTimeInterval(0.5))
        stack.push(3)
        stack.remove(2, at: start.addingTimeInterval(0.6))
        #expect(pop(&stack) == nil)
        #expect(stack.top == 3)
    }

    // An app quitting with several windows: they are all gone by the time
    // focus pops, which skips every one of them.
    @Test func severalWindowsClosingAtOnceSkipTheDead() {
        var stack = stack(1, 2, 3, 4)
        stack.noteNativeSwitch(from: 4, to: 9, at: start)
        stack.push(9)
        stack.remove(4, at: start)
        stack.remove(3, at: start)
        #expect(pop(&stack, alive: [1, 9]) == 1)
        #expect(stack.windowIds == [1])
    }

    @Test func aMinimizedWindowIsSkippedButRemembered() {
        var stack = stack(1, 2, 3)
        stack.remove(3, at: start)
        #expect(pop(&stack, focusable: [1]) == 1)
        #expect(stack.windowIds == [1, 2])
    }

    @Test func aPopHappensOnce() {
        var stack = stack(1, 2)
        stack.remove(2, at: start)
        #expect(pop(&stack) == 1)
        #expect(pop(&stack) == nil)
    }

    @Test func theStackIsBounded() {
        var stack = FocusStack()
        for id in 0 ..< UInt32(FocusStack.limit + 10) { stack.push(id) }
        #expect(stack.windowIds.count == FocusStack.limit)
        #expect(stack.windowIds.first == 10)
    }
}
