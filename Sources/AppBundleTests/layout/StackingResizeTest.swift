@testable import AppBundle
import Common
import Testing
import AppKit

@Suite("StackingResize")
struct StackingResizeTest {
    private let landscapeAvail = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 600)
    private let portraitAvail  = Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 900)

    // MARK: landscape — vertical drag adjusts slot weights

    @Test func landscapeBottomDragGrowsSlotZero() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 300)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 400)
        let result = StackingResize.snap(.init(
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

    @Test func landscapeRightDragGrowsCurrentLaneAndShrinksTheOther() {
        // 6-lane grid; 2 used lanes at the default 0.4 (a centred 0.8 strip).
        // Dragging col 0's right edge gives it its new rendered extent
        // (600/900 = 0.667); col 1 takes the rest of the screen, so the
        // strip now fills it. Unused lanes keep the default column width (0.4).
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 450, height: 600)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 600)
        let result = StackingResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        let lw = result?.laneWeights ?? []
        #expect(lw.count == 6)
        #expect(abs(lw[0] - 0.6667) < 0.01)   // 600 / 900
        #expect(abs(lw[1] - 0.3333) < 0.01)   // 1 − 0.667
        for unused in 2 ..< 6 { #expect(abs(lw[unused] - 0.4) < 0.01) }
        #expect(result?.slotLane == nil)
    }

    @Test func loneColumnResizableOnOuterEdge() {
        // A lone column's edges are "outer" (facing the centred slack), and
        // they DO resize it: dragging the right edge from 450→300 px sets
        // its absolute width to 300/900 = 0.333, rendered centred.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 450, height: 600)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 600)
        let result = StackingResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        let lw = result?.laneWeights ?? []
        #expect(abs(lw[0] - 0.3333) < 0.01)
        layout.setLaneWeights(lw)
        let r = layout.resolveRect(for: 1, in: landscapeAvail, innerGap: 0)
        #expect(abs((r?.width ?? 0) - 300) < 0.01)
        #expect(abs((r?.topLeftX ?? 0) - 300) < 0.01) // (900-300)/2, centred
    }

    // MARK: portrait — axes flip

    @Test func portraitRightDragGrowsSlotZero() {
        let layout = StackingLayout(shape: .portraitDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 300)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 300)
        let result = StackingResize.snap(.init(
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
        let layout = StackingLayout(shape: .portraitDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 450)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 600)
        let result = StackingResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: portraitAvail, innerGap: 0,
        ))
        let lw = result?.laneWeights ?? []
        #expect(lw.count == 6)
        // Portrait lane axis = Y. New extent 600 / usable 900 = 0.667.
        #expect(abs(lw[0] - 0.6667) < 0.01)
        #expect(abs(lw[1] - 0.3333) < 0.01)   // the other row takes the rest
    }

    // MARK: lane-axis drag distributes across ALL lanes on the other side

    @Test func landscapeRightDragThreeUsedLanesShrinksTheOthersInProportion() {
        // 3 used lanes, each rendered 300 px wide (0.333 fraction). Drag
        // lane 0 to 450 px: it becomes 450/900 = 0.5, and the two others
        // share the 0.167 it took, in proportion (0.25 each). Still sums to 1.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        layout.place(3, at: .soleSlot(lane: 2))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 600)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 450, height: 600)
        let result = StackingResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        let lw = result?.laneWeights ?? []
        #expect(lw.count == 6)
        #expect(abs(lw[0] - 0.5) < 0.01)      // 450 / 900
        #expect(abs(lw[1] - 0.25) < 0.01)
        #expect(abs(lw[2] - 0.25) < 0.01)
        for unused in 3 ..< 6 { #expect(abs(lw[unused] - 0.4) < 0.01) }
    }

    @Test func landscapeShrinkingAColumnGrowsTheOthersInProportion() {
        // Widths 0.5 / 0.3 / 0.2 (filling). Shrink col 0 to 0.3: the 0.2 it
        // frees goes to cols 1 and 2 in a 3:2 ratio → 0.42 / 0.28.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        layout.place(3, at: .soleSlot(lane: 2))
        layout.setLaneAbsoluteWidth(0.5, lane: 0)
        layout.setLaneAbsoluteWidth(0.3, lane: 1)
        layout.setLaneAbsoluteWidth(0.2, lane: 2)
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 450, height: 600)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 270, height: 600)
        let result = StackingResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        let lw = result?.laneWeights ?? []
        #expect(abs(lw[0] - 0.3) < 0.001)
        #expect(abs(lw[1] - 0.42) < 0.001)
        #expect(abs(lw[2] - 0.28) < 0.001)
        layout.setLaneWeights(lw)
        let r3 = layout.resolveRect(for: 3, in: landscapeAvail, innerGap: 0)
        #expect(abs((r3?.maxX ?? 0) - 900) < 0.5) // still fills the screen
    }

    @Test func aColumnCannotSqueezeTheOthersAway() {
        // Two filling columns; drag col 0 to the whole screen. Col 1 keeps
        // the floor (minLaneWidth) and col 0 gets the rest.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        layout.setLaneAbsoluteWidth(0.5, lane: 0)
        layout.setLaneAbsoluteWidth(0.5, lane: 1)
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 450, height: 600)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 600)
        let lw = StackingResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))?.laneWeights ?? []
        #expect(abs(lw[1] - StackingResize.minLaneWidth) < 0.001)
        #expect(abs(lw[0] + lw[1] - 1) < 0.001)
    }

    // MARK: jitter and edge cases

    @Test func subPixelJitterIgnored() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 300)
        let cur  = Rect(topLeftX: 0.2, topLeftY: 0.4, width: 299.8, height: 299.7)
        let result = StackingResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        #expect(result == nil)
    }

    @Test func singleSlotLaneNothingToRedistribute() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 600)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 700)
        let result = StackingResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        // Slot drag (bottom) but only 1 slot AND only 1 used lane →
        // both slot and lane redistribution can't happen.
        #expect(result == nil)
    }
}
