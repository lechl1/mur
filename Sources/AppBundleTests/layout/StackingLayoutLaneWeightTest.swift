@testable import AppBundle
import Common
import Testing

/// Regression: the two MurApp crash reports of 2026-10-17 trapped with
/// "Index out of range" in `laneWeight(lane:)`, called from `place` while
/// the startup restore mounted windows. `appendLane()` / `reshape(to:)`
/// grow `shape.lanes` without growing the stored lane-weight array, so
/// once widths had been set, every lane added afterwards indexed past it.
@Suite("StackingLayout lane weights")
struct StackingLayoutLaneWeightTest {
    /// Every existing lane holds a window, so the new one can't be
    /// compacted down into a free lane and really lands in the added lane.
    private func fullLayout() -> StackingLayout {
        let layout = StackingLayout(shape: .landscapeDefault)
        for lane in 0 ..< layout.shape.lanes {
            layout.place(WindowId(UInt32(100 + lane)), at: .single(lane: lane, slot: 0))
        }
        return layout
    }

    @Test func placeIntoAppendedLaneAfterWeightsWereSet() {
        let layout = fullLayout()
        layout.setLaneWeights((0 ..< layout.shape.lanes).map { _ in 0.3 })
        let newLane = layout.appendLane()
        layout.place(WindowId(1), at: .single(lane: newLane, slot: 0))
        #expect(layout.placements[WindowId(1)] == .single(lane: newLane, slot: 0))
        #expect(layout.laneWeight(lane: newLane) == StackingLayout.defaultColumnWidth)
    }

    @Test func placeIntoLaneAddedByReshapeAfterWeightsWereSet() {
        let layout = fullLayout()
        layout.setLaneWeights((0 ..< layout.shape.lanes).map { _ in 0.3 })
        let lanes = layout.shape.lanes + 1
        _ = layout.reshape(to: LayoutShape(orientation: .landscape, lanes: lanes))
        layout.place(WindowId(1), at: .single(lane: lanes - 1, slot: 0))
        #expect(layout.placements[WindowId(1)] == .single(lane: lanes - 1, slot: 0))
    }

    @Test func swapAndInsertAcrossAppendedLanes() {
        let layout = fullLayout()
        layout.setLaneWeights((0 ..< layout.shape.lanes).map { _ in 0.3 })
        let a = layout.appendLane()
        let b = layout.appendLane()
        layout.place(WindowId(1), at: .single(lane: a, slot: 0))
        layout.place(WindowId(2), at: .single(lane: b, slot: 0))
        layout.swapLanes(a, b)
        layout.insertLane(at: b)
        #expect(layout.laneWeight(lane: b + 1) > 0)
    }
}
