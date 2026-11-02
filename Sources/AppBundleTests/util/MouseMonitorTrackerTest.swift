@testable import AppBundle
import Foundation
import Testing

@Suite("focus-follows-mouse-across-monitors")
struct MouseMonitorTrackerTest {
    private let left = CGPoint(x: 0, y: 0)
    private let right = CGPoint(x: 1728, y: -83)

    @Test func onlyACrossingCounts() {
        var tracker = MouseMonitorTracker()
        // left (first sighting: nothing to cross from), left, right, right
        // again (resting on the new monitor doesn't re-fire, so a keyboard
        // focus change back to the old one survives a mouse jiggle), left.
        let crossings = [left, left, right, right, left].map { tracker.crossed(onto: $0) }
        #expect(crossings == [false, false, true, false, true])
    }
}
