@testable import AppBundle
import Common
import Testing
import AppKit

@Suite("GridResize")
struct GridResizeTest {
    private let landscapeAvail = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 600)
    private let portraitAvail  = Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 900)

    // MARK: landscape — vertical drag adjusts slot weights

    @Test func landscapeBottomDragGrowsSlotZero() {
        let layout = GridLayout(shape: .landscapeDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 300)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 400)
        let result = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        #expect(result?.slotLane == 0)
        let w = result?.slotWeights ?? []
        #expect(abs(w[0] - 1.3333) < 0.01)
        #expect(abs(w[1] - 0.6666) < 0.01)
        #expect(result?.laneWeights == nil) // no lane-axis drag here
    }

    @Test func landscapeRightDragGrowsCurrentLane() {
        // 6-lane rigid grid; 2 used lanes (0 and 1). Dragging col 0's
        // right edge grows col 0 and shrinks col 1. Lanes 2..5 are
        // unused → their weights are unchanged at 1.0.
        let layout = GridLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 450, height: 600)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 600)
        let result = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        let lw = result?.laneWeights ?? []
        #expect(lw.count == 6)
        // delta total = (150 / 900) * 2 (used total) = 0.333.
        #expect(abs(lw[0] - 1.3333) < 0.01)
        #expect(abs(lw[1] - 0.6666) < 0.01)
        for unused in 2..<6 { #expect(lw[unused] == 1.0) }
        #expect(result?.slotLane == nil)
    }

    // MARK: portrait — axes flip

    @Test func portraitRightDragGrowsSlotZero() {
        let layout = GridLayout(shape: .portraitDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 300)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 300)
        let result = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: portraitAvail, innerGap: 0,
        ))
        #expect(result?.slotLane == 0)
        let w = result?.slotWeights ?? []
        #expect(abs(w[0] - 1.3333) < 0.01)
        #expect(abs(w[1] - 0.6666) < 0.01)
    }

    @Test func portraitBottomDragGrowsCurrentLane() {
        // 6-lane portrait grid, 2 used. Bottom drag grows lane 0.
        let layout = GridLayout(shape: .portraitDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 450)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 600)
        let result = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: portraitAvail, innerGap: 0,
        ))
        let lw = result?.laneWeights ?? []
        #expect(lw.count == 6)
        #expect(abs(lw[0] - 1.3333) < 0.01)
        #expect(abs(lw[1] - 0.6666) < 0.01)
    }

    // MARK: lane-axis drag distributes across ALL lanes on the other side

    @Test func landscapeRightDragWithThreeUsedLanesDistributesEvenly() {
        // 3 used lanes; drag lane 0's right edge to the right by 150 px on
        // a 900 px screen. Lane 0 should grow by 150; lanes 1 and 2 should
        // each shrink by 75 (not lane 1 by 150 + lane 2 unchanged).
        let layout = GridLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        layout.place(3, at: .soleSlot(lane: 2))
        // Each lane starts at 300 px wide.
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 600)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 450, height: 600)
        let result = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        let lw = result?.laneWeights ?? []
        #expect(lw.count == 6)
        // delta total = 150 / 900 * 3 = 0.5. Split across 2 → 0.25 each.
        #expect(abs(lw[0] - 1.5) < 0.01)
        #expect(abs(lw[1] - 0.75) < 0.01)
        #expect(abs(lw[2] - 0.75) < 0.01)
        for unused in 3..<6 { #expect(lw[unused] == 1.0) }
    }

    // MARK: jitter and edge cases

    @Test func subPixelJitterIgnored() {
        let layout = GridLayout(shape: .landscapeDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 300)
        let cur  = Rect(topLeftX: 0.2, topLeftY: 0.4, width: 299.8, height: 299.7)
        let result = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        #expect(result == nil)
    }

    @Test func singleSlotLaneNothingToRedistribute() {
        let layout = GridLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 600)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 700)
        let result = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        // Slot drag (bottom) but only 1 slot AND only 1 used lane →
        // both slot and lane redistribution can't happen.
        #expect(result == nil)
    }
}
