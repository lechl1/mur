@testable import AppBundle
import Common
import Testing

@Suite("StackingResizeStep")
struct StackingResizeStepTest {
    // MARK: ladder snapping

    @Test func ladderIsSymmetricAroundHalf() {
        let ladder = StackingResize.resizeFractionLadder
        // Always contains 1/2 exactly once.
        let halfIdx = ladder.firstIndex(of: 0.5)
        #expect(halfIdx != nil)
        // Endpoints: 1/16 and 15/16.
        #expect(abs((ladder.first ?? 0) - (1.0 / 16.0)) < 0.001)
        #expect(abs((ladder.last ?? 0) - (15.0 / 16.0)) < 0.001)
    }

    @Test func nearestLadderIndexFindsExactMatch() {
        let idx = StackingResize.nearestLadderIndex(for: 0.5)
        #expect(StackingResize.resizeFractionLadder[idx] == 0.5)
    }

    // MARK: lane resize — shrink walks fractions toward 1/16

    @Test func shrinkLaneAtFiftyPercent() {
        // 2 lanes, both 1.0 → each at 50%. Shrink lane 0 → ladder
        // contains a midpoint between 1/2 and 1/3, so the first step
        // lands on (1/2 + 1/3)/2 = 5/12 ≈ 0.4167.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        StackingResize.resizeLane(layout: layout, lane: 0, signum: -1)
        let total = layout.laneWeight(lane: 0) + layout.laneWeight(lane: 1)
        let f0 = layout.laneWeight(lane: 0) / total
        #expect(abs(f0 - 5.0 / 12.0) < 0.01)
    }

    @Test func shrinkLaneClampsAtSixteenth() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        for _ in 0..<30 {
            StackingResize.resizeLane(layout: layout, lane: 0, signum: -1)
        }
        let total = layout.laneWeight(lane: 0) + layout.laneWeight(lane: 1)
        let f0 = layout.laneWeight(lane: 0) / total
        #expect(f0 >= (1.0 / 16.0) - 0.001)
        #expect(f0 <= (1.0 / 16.0) + 0.01)
    }

    // MARK: lane resize — grow walks fractions toward 15/16

    @Test func growLaneAtFiftyPercent() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        StackingResize.resizeLane(layout: layout, lane: 0, signum: +1)
        let total = layout.laneWeight(lane: 0) + layout.laneWeight(lane: 1)
        let f0 = layout.laneWeight(lane: 0) / total
        // 1/2 → midpoint(1/2, 2/3) = 7/12 ≈ 0.583.
        #expect(abs(f0 - 7.0 / 12.0) < 0.01)
    }

    @Test func growLaneClampsAtFifteenSixteenths() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        for _ in 0..<30 {
            StackingResize.resizeLane(layout: layout, lane: 0, signum: +1)
        }
        let total = layout.laneWeight(lane: 0) + layout.laneWeight(lane: 1)
        let f0 = layout.laneWeight(lane: 0) / total
        #expect(f0 <= (15.0 / 16.0) + 0.001)
        #expect(f0 >= (15.0 / 16.0) - 0.01)
    }

    // MARK: slot resize

    @Test func shrinkSlotAtFiftyPercent() {
        // Two slots stacked in lane 0, equal weights → 50/50. Shrink
        // lands on midpoint(1/2, 1/3) = 5/12.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        StackingResize.resizeSlot(layout: layout, lane: 0, slot: 0, signum: -1)
        let w0 = layout.slotWeight(lane: 0, slot: 0)
        let w1 = layout.slotWeight(lane: 0, slot: 1)
        let f0 = w0 / (w0 + w1)
        #expect(abs(f0 - 5.0 / 12.0) < 0.01)
    }

    // MARK: no-op when only one lane is used (no others to absorb)

    @Test func resizeSingleUsedLaneIsNoOp() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        let before = layout.laneWeight(lane: 0)
        StackingResize.resizeLane(layout: layout, lane: 0, signum: -1)
        #expect(layout.laneWeight(lane: 0) == before)
    }
}
