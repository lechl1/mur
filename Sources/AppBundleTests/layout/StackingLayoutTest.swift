@testable import AppBundle
import Common
import Testing
import AppKit

@Suite("StackingLayout")
struct StackingLayoutTest {
    private let landscapeAvail = Rect(topLeftX: 0, topLeftY: 0, width: 900, height: 600)
    private let portraitAvail  = Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 900)

    // MARK: orientation detection

    @Test func orientationFromMonitor() {
        #expect(LayoutOrientation.forMonitor(width: 1920, height: 1080) == .landscape)
        #expect(LayoutOrientation.forMonitor(width: 1080, height: 1920) == .portrait)
        // Square defaults to landscape.
        #expect(LayoutOrientation.forMonitor(width: 1000, height: 1000) == .landscape)
    }

    // MARK: per-lane slot counts (the user's "left col 4 rows, right col 3" requirement)

    @Test func laneSlotCountsAreIndependent() {
        let layout = StackingLayout(shape: .landscapeDefault) // 3 lanes
        // Lane 0: 4 slots (left column has 4 rows in landscape)
        for s in 0..<4 { layout.place(WindowId(100 + s), at: .single(lane: 0, slot: s)) }
        // Lane 1: 2 slots (middle column 2 rows)
        for s in 0..<2 { layout.place(WindowId(200 + s), at: .single(lane: 1, slot: s)) }
        // Lane 2: 3 slots (right column 3 rows)
        for s in 0..<3 { layout.place(WindowId(300 + s), at: .single(lane: 2, slot: s)) }

        #expect(layout.slotCount(in: 0) == 4)
        #expect(layout.slotCount(in: 1) == 2)
        #expect(layout.slotCount(in: 2) == 3)
    }

    // MARK: empty-lane collapse

    @Test func emptyLanesCollapseLandscape() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        // Only lane 0 in use → 1 used lane, full width.
        let r = layout.resolveRect(for: 1, in: landscapeAvail, innerGap: 0)
        #expect(r?.width == 900)
        #expect(r?.height == 600)
    }

    @Test func emptyLanesCollapsePortrait() {
        let layout = StackingLayout(shape: .portraitDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        // In portrait, lane axis is Y. One used lane → full height, full width.
        let r = layout.resolveRect(for: 1, in: portraitAvail, innerGap: 0)
        #expect(r?.width == 600)
        #expect(r?.height == 900)
    }

    // MARK: slot weights — equal partition by default

    @Test func twoSlotsInLaneSplitFiftyFiftyLandscape() {
        let layout = StackingLayout(shape: .landscapeDefault)
        // Two windows in lane 0 → lane uses full width (other lanes empty),
        // partitioned vertically 50/50 by default weights.
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        let r1 = layout.resolveRect(for: 1, in: landscapeAvail)
        let r2 = layout.resolveRect(for: 2, in: landscapeAvail)
        #expect(r1?.height == 300)
        #expect(r2?.height == 300)
        #expect(r1?.topLeftY == 0)
        #expect(r2?.topLeftY == 300)
    }

    @Test func slotWeightsRedistribute() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        // Make slot 0 take 2/3 of the height by setting weights [2, 1].
        layout.setSlotWeights(lane: 0, weights: [2, 1])
        let r1 = layout.resolveRect(for: 1, in: landscapeAvail)
        let r2 = layout.resolveRect(for: 2, in: landscapeAvail)
        #expect(r1?.height == 400)  // 2/3 * 600
        #expect(r2?.height == 200)
    }

    // MARK: portrait orientation: rows are rigid

    @Test func portraitFlipsLaneAxis() {
        let layout = StackingLayout(shape: .portraitDefault) // 3 rigid rows
        layout.place(1, at: .soleSlot(lane: 0)) // top row
        layout.place(2, at: .soleSlot(lane: 1)) // middle row
        layout.place(3, at: .soleSlot(lane: 2)) // bottom row
        let r1 = layout.resolveRect(for: 1, in: portraitAvail)
        let r3 = layout.resolveRect(for: 3, in: portraitAvail)
        // Each row is 300 tall; window 1 at top (y=0), window 3 at y=600.
        #expect(r1?.height == 300)
        #expect(r1?.topLeftY == 0)
        #expect(r3?.topLeftY == 600)
        #expect(r1?.width == 600)  // full width since each row has 1 slot
    }

    // MARK: placement heuristic

    @Test func newWindowOnEmptyWorkspaceGoesToLaneZero() {
        let layout = StackingLayout()
        let span = layout.placementForNewWindow()
        #expect(span == .soleSlot(lane: 0))
    }

    @Test func newWindowSingleLaneOpensFreshLane() {
        // Single-column (landscape) / single-row (portrait) layout: the
        // 2nd window goes into a fresh lane so we move from stacked to
        // side-by-side instead of stacking another tile in the only lane.
        let layout = StackingLayout()
        layout.place(1, at: .soleSlot(lane: 0))
        let span = layout.placementForNewWindow(focusedLane: 0)
        #expect(span == .soleSlot(lane: 1))
    }

    @Test func newWindowSingleLaneOpensFreshLaneEvenWithoutFocus() {
        // Same single-lane → fresh-lane behavior when no focus is given.
        let layout = StackingLayout()
        layout.place(1, at: .soleSlot(lane: 0))
        let span = layout.placementForNewWindow()
        #expect(span == .soleSlot(lane: 1))
    }

    @Test func newWindowSingleLaneAtRightEdgeAppendsLane() {
        // Single used lane sits at the right edge of the shape — no
        // empty lane to its right, so the shape grows by one.
        let layout = StackingLayout(shape: LayoutShape(orientation: .landscape, lanes: 1))
        layout.place(1, at: .soleSlot(lane: 0))
        let span = layout.placementForNewWindow()
        #expect(span == .soleSlot(lane: 1))
        #expect(layout.shape.lanes == 2)
    }

    @Test func newWindowStacksInFocusedLaneOnceMultiLane() {
        // Two used lanes → stacking behavior kicks back in: focused
        // lane gets a new slot below the existing tile.
        let layout = StackingLayout()
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        let span = layout.placementForNewWindow(focusedLane: 0)
        #expect(span == .single(lane: 0, slot: 1))
    }

    @Test func newWindowStacksInRightmostUsedWhenNoFocus() {
        let layout = StackingLayout()
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        // No focusedLane → use rightmost used (lane 1).
        let span = layout.placementForNewWindow()
        #expect(span == .single(lane: 1, slot: 1))
    }

    // MARK: multi-lane spans (TileSpan generalization)

    @Test func multiLaneSpanWidthCoversBothLanes() {
        // Single window spanning lanes 0..1 in landscape — its rect should
        // cover the union of both lanes' widths (no third lane in use).
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: TileSpan(lane0: 0, lane1: 1, slot0: 0, slot1: 0))
        let r = layout.resolveRect(for: 1, in: landscapeAvail, innerGap: 0)
        // Two USED lanes with default weights → 50/50 split. Span covers
        // both → full 900px width, full 600px height.
        #expect(r?.width == 900)
        #expect(r?.height == 600)
        #expect(r?.topLeftX == 0)
    }

    @Test func multiLaneSpanWithThirdLaneSibling() {
        // 3 lanes used; window 1 spans lanes 0..1, window 2 occupies lane 2.
        // Default lane weights → each lane is 300px wide. Window 1 → 600px,
        // window 2 → 300px.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: TileSpan(lane0: 0, lane1: 1, slot0: 0, slot1: 0))
        layout.place(2, at: .soleSlot(lane: 2))
        let r1 = layout.resolveRect(for: 1, in: landscapeAvail, innerGap: 0)
        let r2 = layout.resolveRect(for: 2, in: landscapeAvail, innerGap: 0)
        #expect(r1?.width == 600)
        #expect(r1?.topLeftX == 0)
        #expect(r2?.width == 300)
        #expect(r2?.topLeftX == 600)
    }

    @Test func multiLaneSpanContributesToUsedLanes() {
        let layout = StackingLayout(shape: .landscapeDefault) // 6 lanes
        layout.place(1, at: TileSpan(lane0: 0, lane1: 2, slot0: 0, slot1: 0))
        #expect(layout.usedLanes == [0, 1, 2])
        #expect(layout.emptyLanes == [3, 4, 5])
    }

    @Test func backwardCompatibleSingleLaneInit() {
        // The legacy `init(lane:slot0:slot1:)` should still produce
        // `lane0 == lane1` spans.
        let span = TileSpan(lane: 1, slot0: 0, slot1: 0)
        #expect(span.lane0 == 1)
        #expect(span.lane1 == 1)
        #expect(span.isSingleLane)
        #expect(span.laneCount == 1)
    }

    // MARK: column / row swap

    @Test func swapLanesMovesAllPlacements() {
        // Two windows in lane 0, one in lane 1. Swap lanes 0 ↔ 1.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        layout.place(3, at: .soleSlot(lane: 1))
        layout.swapLanes(0, 1)
        #expect(layout.placements[1] == .single(lane: 1, slot: 0))
        #expect(layout.placements[2] == .single(lane: 1, slot: 1))
        #expect(layout.placements[3] == .soleSlot(lane: 0))
    }

    @Test func swapLanesPreservesPerLaneSlotWeights() {
        // Lane 0 has slot weights [2, 1]; lane 1 has [1]. After swap,
        // each column's row partition follows it.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        layout.place(3, at: .soleSlot(lane: 1))
        layout.setSlotWeights(lane: 0, weights: [2, 1])
        layout.swapLanes(0, 1)
        // The 2:1 partition should now belong to lane 1.
        #expect(layout.slotWeight(lane: 1, slot: 0) == 2)
        #expect(layout.slotWeight(lane: 1, slot: 1) == 1)
    }

    @Test func swapLanesSwapsLaneWeights() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        var weights = [CGFloat](repeating: 1.0, count: 6)
        weights[0] = 3
        weights[1] = 1
        layout.setLaneWeights(weights)
        layout.swapLanes(0, 1)
        #expect(layout.laneWeight(lane: 0) == 1)
        #expect(layout.laneWeight(lane: 1) == 3)
    }

    @Test func appendLaneGrowsShape() {
        let layout = StackingLayout(shape: .landscapeDefault)
        let before = layout.shape.lanes
        let newIdx = layout.appendLane()
        #expect(newIdx == before)
        #expect(layout.shape.lanes == before + 1)
    }

    @Test func insertLaneAtFrontShiftsPlacements() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        layout.insertLaneAtFront()
        // Both windows shifted right by 1.
        #expect(layout.placements[1] == .soleSlot(lane: 1))
        #expect(layout.placements[2] == .soleSlot(lane: 2))
        #expect(layout.shape.lanes == 7)
    }

    @Test func insertSlotAtFrontShiftsPlacementsInLane() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        layout.place(3, at: .soleSlot(lane: 1)) // different lane — should NOT shift
        layout.insertSlotAtFront(in: 0)
        #expect(layout.placements[1] == .single(lane: 0, slot: 1))
        #expect(layout.placements[2] == .single(lane: 0, slot: 2))
        #expect(layout.placements[3] == .soleSlot(lane: 1))
    }

    @Test func swapSlotsWithinLane() {
        // Two windows stacked in lane 0. Swap rows.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .single(lane: 0, slot: 0))
        layout.place(2, at: .single(lane: 0, slot: 1))
        layout.swapSlots(in: 0, 0, 1)
        #expect(layout.placements[1] == .single(lane: 0, slot: 1))
        #expect(layout.placements[2] == .single(lane: 0, slot: 0))
    }

    // MARK: rigid lane axis

    // MARK: zOrder

    @Test func placePromotesToTopOfZOrder() {
        let layout = StackingLayout()
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        #expect(layout.zOrder == [1, 2])
        layout.place(1, at: .soleSlot(lane: 0))
        #expect(layout.zOrder == [2, 1])
    }
}
