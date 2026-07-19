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

    @Test func landscapeRightDragGrowsCurrentLaneAbsolute() {
        // 6-lane grid; 2 used lanes (0.5 each → filling). Dragging col 0's
        // right edge sets col 0's ABSOLUTE width from its new rendered
        // extent (600/900 = 0.667); col 1 is snapshotted at its current
        // rendered fraction (0.5). fit-or-center then re-renders. Unused
        // lanes stay at the default column width (0.5).
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
        #expect(abs(lw[1] - 0.4) < 0.01)      // snapshot of its rendered width
        for unused in 2..<6 { #expect(abs(lw[unused] - 0.4) < 0.01) }
        #expect(result?.slotLane == nil)
    }

    @Test func loneColumnNotResizableOnLaneAxis() {
        // A lone column is both left-most and right-most, so both its
        // lane-axis edges are "outer" (facing the centred slack) and are
        // pinned — dragging them does nothing.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 450, height: 600)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 600)
        let result = StackingResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        #expect(result == nil)
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
        #expect(abs(lw[1] - 0.4) < 0.01)
    }

    // MARK: lane-axis drag distributes across ALL lanes on the other side

    @Test func landscapeRightDragThreeUsedLanesGrowsDraggedKeepsNeighbours() {
        // 3 used lanes, each rendered 300 px wide (0.333 fraction). Drag
        // lane 0 to 450 px. Its absolute width becomes 450/900 = 0.5; the
        // neighbours are snapshotted at their rendered fraction (0.333) and
        // kept — fit-or-center then shrinks everything to fit (sum 1.167).
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
        #expect(abs(lw[1] - 0.3333) < 0.01)   // snapshot of rendered 300 px
        #expect(abs(lw[2] - 0.3333) < 0.01)
        for unused in 3..<6 { #expect(abs(lw[unused] - 0.4) < 0.01) }
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
