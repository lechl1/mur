@testable import AppBundle
import Testing

/// mur — a release build without Accessibility waits for the grant instead
/// of quitting, then carries on with startup.
@Suite("AccessibilityWait")
struct AccessibilityWaitTest {
    @Test func itReturnsAsSoonAsTheGrantArrives() async throws {
        var asked = 0
        try await waitUntilTrusted({
            asked += 1
            return asked == 3
        }, every: .milliseconds(1))
        #expect(asked == 3)
    }

    @Test func anAlreadyTrustedProcessDoesNotWait() async throws {
        var asked = 0
        try await waitUntilTrusted({
            asked += 1
            return true
        }, every: .seconds(60))
        #expect(asked == 1)
    }
}
