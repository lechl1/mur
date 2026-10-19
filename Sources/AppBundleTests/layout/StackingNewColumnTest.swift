@testable import AppBundle
import Common
import Foundation
import Testing

private let avail = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 600)

@Suite("StackingLayout new column / row moves")
struct StackingNewColumnTest {
    // MARK: a new column beside a full screen takes an equal share

    @Test func newColumnBesideAFullWidthColumnSplitsFiftyFifty() {
        // One terminal covering the whole width (weight 1 after a close),
        // then a second opens: both end up half the screen, not 1/3 each
        // and not 75/25.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.setLaneAbsoluteWidth(1, lane: 0)
        let width = StackingLayout.widthForNewColumn(natural: 1.0 / 3.0, existing: [layout.laneWeight(lane: 0)])
        layout.place(2, at: .soleSlot(lane: 1))
        layout.setLaneAbsoluteWidth(width, lane: 1)
        let r0 = layout.resolveRect(for: 1, in: avail, innerGap: 0)
        let r1 = layout.resolveRect(for: 2, in: avail, innerGap: 0)
        #expect(abs((r0?.width ?? 0) - 450) < 0.001)
        #expect(abs((r1?.width ?? 0) - 450) < 0.001)
        #expect(abs((r0?.topLeftX ?? -1) - 0) < 0.001)
    }

    @Test func newColumnBesideANarrowStripKeepsItsNaturalWidth() {
        // Fit-or-center still holds while the strip doesn't fill the axis.
        #expect(abs(StackingLayout.widthForNewColumn(natural: 1.0 / 3.0, existing: [1.0 / 3.0]) - 1.0 / 3.0) < 0.001)
        #expect(StackingLayout.widthForNewColumn(natural: 0.4, existing: []) == 0.4)
    }

    @Test func newColumnBesideFilledColumnsGetsTheirAverage() {
        // Two columns filling the screen 0.25 / 0.75 → the newcomer gets
        // 0.5, i.e. a third of the screen, and the others keep their ratio.
        #expect(abs(StackingLayout.widthForNewColumn(natural: 1.0 / 3.0, existing: [0.25, 0.75]) - 0.5) < 0.001)
    }

    // MARK: moving a row down / up (stacking-move on the slot axis)

    @Test func placingAtTheNextSlotDoesNotMoveAWindowDown() {
        // Why stacking-move swaps instead of placing at the neighbour's
        // slot: `place` inserts, so this round-trips to where it started.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        layout.place(1, at: .single(lane: 0, slot: 1))
        #expect(layout.placements[1]?.slot0 == 0)
        #expect(layout.placements[2]?.slot0 == 1)
    }

    @Test func swappingRowsMovesAWindowDownAndUp() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        layout.swapSlots(in: 0, 0, 1) // down
        #expect(layout.placements[1]?.slot0 == 1)
        #expect(layout.placements[2]?.slot0 == 0)
        layout.swapSlots(in: 0, 1, 0) // and back up
        #expect(layout.placements[1]?.slot0 == 0)
        #expect(layout.placements[2]?.slot0 == 1)
    }
}
