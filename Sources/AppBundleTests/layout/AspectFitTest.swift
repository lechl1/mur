@testable import AppBundle
import Foundation
import Testing

@Suite("aspect-locked windows")
struct AspectFitTest {
    // VLC with a 4:3 video, as measured: 800 wide → 664 tall, and clamped
    // to its minimum 604 × 517 when asked for less.
    private let vlc = AspectLock(CGSize(width: 800, height: 664), CGSize(width: 604, height: 517))

    @Test func theLineThroughTwoSizesIsTheVideoPlusTheToolbar() {
        #expect(vlc?.slope == 0.75)
        #expect(vlc?.offset == 64)
    }

    @Test func aWindowTallerThanTheScreenIsNarrowedToFitAndCentred() {
        // A 1536-wide column on a 1200-tall screen: 0.75 * 1536 + 64 = 1216.
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 1536, height: 1200)
        let fit = aspectFit(cell, lock: vlc)
        #expect(fit.height == 1200)
        #expect(fit.width == 1514) // (1200 - 64) / 0.75
        #expect(fit.topLeftX == 11) // (1536 - 1514) / 2
    }

    @Test func neverNarrowerThanTheWindowsMinimumWidth() {
        // A 361-tall row: the fit says 396 wide, VLC won't go below 604.
        let cell = Rect(topLeftX: 428, topLeftY: 34, width: 800, height: 361)
        let fit = aspectFit(cell, lock: vlc, minimumWidth: 604)
        #expect(fit.width == 604)
        #expect(fit.topLeftX == 526) // centred: 428 + (800 - 604) / 2
    }

    @Test func aWindowThatFitsKeepsItsCell() {
        let cell = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 1200)
        let fit = aspectFit(cell, lock: vlc)
        #expect(fit.width == 800 && fit.topLeftX == 0)
    }

    @Test func noLockMeansTheCell() {
        let cell = Rect(topLeftX: 5, topLeftY: 0, width: 800, height: 300)
        #expect(aspectFit(cell, lock: nil).width == 800)
    }

    @Test func aSizeThatDoesNotShrinkWithTheWidthIsNoLock() {
        // A minimum height: narrower, same height.
        #expect(AspectLock(CGSize(width: 800, height: 664), CGSize(width: 434, height: 664)) == nil)
        #expect(AspectLock(CGSize(width: 800, height: 664), CGSize(width: 800, height: 517)) == nil)
    }
}
