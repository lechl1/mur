@testable import AppBundle
import Common
import Foundation
import Testing

/// mur — telling a window mur parked in a corner from one that is showing,
/// and where it goes back to.
@Suite("HiddenWindows")
struct HiddenWindowsTest {
    private let screen = Rect(topLeftX: 0, topLeftY: 40, width: 2056, height: 1289)

    @Test func aWindowParkedInTheCornerIsOffscreen() {
        // `hideInCorner` leaves 1px of the window on the bottom-right corner.
        let parked = Rect(topLeftX: 2055, topLeftY: 1328, width: 800, height: 600)
        #expect(isParkedOffscreen(parked, on: [screen]))
        #expect(visibleFraction(parked, on: [screen]) < 0.001)
    }

    @Test func aWindowOnScreenIsNot() {
        #expect(!isParkedOffscreen(Rect(topLeftX: 100, topLeftY: 100, width: 800, height: 600), on: [screen]))
        // Mostly off the edge, but plainly visible.
        #expect(!isParkedOffscreen(Rect(topLeftX: 1856, topLeftY: 100, width: 800, height: 600), on: [screen]))
    }

    @Test func aSecondMonitorCounts() {
        let right = Rect(topLeftX: 2056, topLeftY: 0, width: 1920, height: 1080)
        let onRight = Rect(topLeftX: 2200, topLeftY: 100, width: 800, height: 600)
        #expect(isParkedOffscreen(onRight, on: [screen]))
        #expect(!isParkedOffscreen(onRight, on: [screen, right]))
    }

    @Test func itComesBackCentredAndNoBiggerThanTheScreen() {
        let small = onscreenFrame(size: CGSize(width: 800, height: 600), in: screen)
        #expect(small.topLeft == CGPoint(x: 628, y: 384.5))
        #expect(small.size == CGSize(width: 800, height: 600))
        let huge = onscreenFrame(size: CGSize(width: 5000, height: 3000), in: screen)
        #expect(huge.topLeft == CGPoint(x: 0, y: 40))
        #expect(huge.size == CGSize(width: 2056, height: 1289))
    }
}
