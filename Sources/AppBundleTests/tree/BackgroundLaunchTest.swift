@testable import AppBundle
import Foundation
import Testing

@Suite("BackgroundLaunch")
struct BackgroundLaunchTest {
    let launch = Date(timeIntervalSinceReferenceDate: 1000)

    func declines(background: Bool?, after seconds: TimeInterval, click: TimeInterval? = nil) -> Bool {
        BackgroundLaunch.declinesFocus(
            startedInBackground: background,
            launchDate: launch,
            lastUserClick: click.map { launch.addingTimeInterval($0) },
            now: launch.addingTimeInterval(seconds),
        )
    }

    @Test func anAppStartedWithNoLauncherDoesNotTakeFocus() {
        #expect(declines(background: true, after: 1))
    }

    @Test func anAppTheUserLaunchedTakesFocus() { // Dock, Spotlight, Finder, Raycast, a terminal
        #expect(!declines(background: false, after: 1))
    }

    @Test func anUnknownOriginFollowsAsBefore() {
        #expect(!declines(background: nil, after: 1))
    }

    @Test func afterTheGraceItIsAnOrdinaryApp() {
        #expect(declines(background: true, after: BackgroundLaunch.grace - 0.1))
        #expect(!declines(background: true, after: BackgroundLaunch.grace + 0.1))
    }

    @Test func aClickAfterTheLaunchHandsItFocus() {
        #expect(!declines(background: true, after: 3, click: 2))
    }

    @Test func aClickBeforeTheLaunchDoesNot() {
        #expect(declines(background: true, after: 3, click: -5))
    }

    @Test func noLaunchDateFollowsAsBefore() {
        #expect(!BackgroundLaunch.declinesFocus(startedInBackground: true, launchDate: nil, lastUserClick: nil, now: launch))
    }
}
