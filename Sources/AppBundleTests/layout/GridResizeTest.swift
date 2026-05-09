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
        // NEW: lane-axis drag is no longer a no-op. AeroSpace-style:
        // dragging the right edge grows the current column and shrinks
        // the next USED column.
        let layout = GridLayout(shape: .landscapeDefault)
        // 2 lanes used (0 and 1) → each starts at width 450 in 900px.
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 450, height: 600)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 600)
        let result = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        // delta = (150 / 900) * 2 = 0.333. Lane 0 gains, lane 1 loses.
        let lw = result?.laneWeights ?? []
        #expect(lw.count == 3)
        #expect(abs(lw[0] - 1.3333) < 0.01)
        #expect(abs(lw[1] - 0.6666) < 0.01)
        #expect(lw[2] == 1.0) // lane 2 unused, weight unchanged
        #expect(result?.slotLane == nil) // no slot-axis drag
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
        // In portrait, lane axis = Y. Bottom drag grows current row (lane).
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
        #expect(lw.count == 3)
        #expect(abs(lw[0] - 1.3333) < 0.01)
        #expect(abs(lw[1] - 0.6666) < 0.01)
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
