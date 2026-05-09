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
        // Initial split: 300/300. User drags window 1's bottom edge from
        // y=300 down to y=400 — slot 0 should grow by 100/600 = 1/6 of total.
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 300)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 400)
        let result = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        #expect(result?.lane == 0)
        // weights start [1,1] (total=2). Delta = (100/600)*2 = 0.333…
        // → [1.333…, 0.666…]
        #expect(abs((result?.weights[0] ?? 0) - 1.3333) < 0.01)
        #expect(abs((result?.weights[1] ?? 0) - 0.6666) < 0.01)
    }

    @Test func landscapeHorizontalDragIsRigidNoOp() {
        let layout = GridLayout(shape: .landscapeDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        // User drags right edge horizontally only — no slot-axis change
        // in landscape → no-op.
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 300)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 450, height: 300)
        let result = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: landscapeAvail, innerGap: 0,
        ))
        #expect(result == nil)
    }

    // MARK: portrait — axes flip

    @Test func portraitRightDragGrowsSlotZero() {
        let layout = GridLayout(shape: .portraitDefault)
        // Lane 0 is the top ROW (rigid); slots within it are columns.
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        // In portrait, slot axis = X. User drags window 1's right edge
        // from x=300 right to x=400.
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 300)
        let cur  = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 300)
        let result = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: portraitAvail, innerGap: 0,
        ))
        #expect(result?.lane == 0)
        // (100/600)*2 ≈ 0.333 transferred from slot 1 to slot 0.
        #expect(abs((result?.weights[0] ?? 0) - 1.3333) < 0.01)
        #expect(abs((result?.weights[1] ?? 0) - 0.6666) < 0.01)
    }

    @Test func portraitVerticalDragIsRigidNoOp() {
        let layout = GridLayout(shape: .portraitDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        let last = Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 300)
        let cur  = Rect(topLeftX: 0, topLeftY: 100, width: 300, height: 200) // top moved down
        let result = GridResize.snap(.init(
            layout: layout, windowId: 1,
            lastAppliedRect: last, currentRect: cur,
            available: portraitAvail, innerGap: 0,
        ))
        // Top edge change is along the LANE axis in portrait → no-op.
        #expect(result == nil)
    }

    // MARK: jitter and single-slot lanes

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
        // Lane has only 1 slot → no neighbour to take weight from.
        #expect(result == nil)
    }
}
