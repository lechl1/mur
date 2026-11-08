@testable import AppBundle
import Common
import Testing

@Suite("restore mode ends on a move the user makes")
struct RestoreModeTest {
    private let before: [WindowId: String] = [1: "2:0:0", 2: "2:1:0"]
    private let moved: [WindowId: String] = [1: "3:0:0", 2: "2:0:0"]

    @Test func aHotkeyThatMovesAWindowIsTheUsersMove() {
        #expect(movedByUser(.hotkeyBinding, before: before, after: moved))
        #expect(movedByUser(.menuBarButton, before: before, after: moved))
    }

    @Test func aHotkeyThatOnlyFocusesMovesNothing() {
        #expect(!movedByUser(.hotkeyBinding, before: before, after: before))
    }

    @Test func aRefreshMacOSStartedIsNotTheUsersMove() {
        // The restore itself moves windows; that must not end restore mode.
        #expect(!movedByUser(.ax("restore-window-state"), before: before, after: moved))
        #expect(!movedByUser(.startup, before: before, after: moved))
    }
}
