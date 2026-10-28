@testable import AppBundle
import Foundation
import Testing

@Suite("Windows macOS reopened at login")
struct LoginRestoreTest {
    private let login = Date(timeIntervalSince1970: 1_000_000)

    @Test func appLaunchedInTheLoginBurstWasReopenedByMacOS() {
        #expect(isLoginBurstLaunch(app: login, login: login))
        #expect(isLoginBurstLaunch(app: login.addingTimeInterval(8), login: login))
        #expect(isLoginBurstLaunch(app: login.addingTimeInterval(loginBurst), login: login))
    }

    @Test func appLaunchedAfterTheBurstWasOpenedByTheUser() {
        #expect(!isLoginBurstLaunch(app: login.addingTimeInterval(loginBurst + 1), login: login))
    }

    @Test func appRunningSinceAnEarlierSessionIsNotPartOfThisLogin() {
        #expect(!isLoginBurstLaunch(app: login.addingTimeInterval(-1), login: login))
    }

    @Test func unknownDatesNeverCount() {
        #expect(!isLoginBurstLaunch(app: nil, login: login))
        #expect(!isLoginBurstLaunch(app: login, login: nil))
    }
}
