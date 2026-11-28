@testable import AppBundle
import AppKit
import Common
import Testing

/// A strip using at least 75% of the lane axis fills it; below that it
/// renders at its own widths, centred.
@Suite("StackingLayout fill threshold")
struct StackingFillThresholdTest {
    private let avail = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)

    private func layout(_ widths: [CGFloat], shape: LayoutShape = .landscapeDefault) -> StackingLayout {
        let l = StackingLayout(shape: shape)
        for i in widths.indices { l.place(WindowId(100 + i), at: .soleSlot(lane: i)) }
        l.setLaneWeights(widths + Array(repeating: 0.4, count: l.shape.lanes - widths.count))
        return l
    }

    @Test func aStripBelowTheThresholdIsCentred() {
        let r = layout([0.35, 0.35]).resolveRect(for: 100, in: avail)
        #expect(abs((r?.width ?? 0) - 350) < 1e-6)
        #expect(abs((r?.topLeftX ?? 0) - 150) < 1e-6)
    }

    @Test func aStripAtTheThresholdFills() {
        let l = layout([0.4, 0.4])
        let a = l.resolveRect(for: 100, in: avail), b = l.resolveRect(for: 101, in: avail)
        #expect(abs((a?.topLeftX ?? -1) - 0) < 1e-6)
        #expect(abs((a?.width ?? 0) - 500) < 1e-6)
        #expect(abs(((b?.topLeftX ?? 0) + (b?.width ?? 0)) - 1000) < 1e-6)
    }

    @Test func aLoneWideColumnFills() {
        let r = layout([0.8]).resolveRect(for: 100, in: avail)
        #expect(abs((r?.width ?? 0) - 1000) < 1e-6)
    }

    @Test func portraitFillsTheHeight() {
        let portrait = Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 1000)
        let r = layout([0.8], shape: .portraitDefault).resolveRect(for: 100, in: portrait)
        #expect(abs((r?.height ?? 0) - 1000) < 1e-6)
    }

    @Test func aLoneFullColumnShrinkingStepsBelowTheThreshold() {
        let l = layout([1.0])
        StackingResize.resizeLaneWidth(layout: l, lane: 0, signum: -1)
        let r = l.resolveRect(for: 100, in: avail)
        #expect((r?.width ?? 1000) < 750)
    }
}
