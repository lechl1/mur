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
        // Only lane 0 in use. With the default column width (0.4) a lone
        // column renders at 40% width, horizontally CENTERED (fit-or-center),
        // and fills the height. Empty lanes still take no space.
        let r = layout.resolveRect(for: 1, in: landscapeAvail, innerGap: 0)
        #expect(r?.width == 360)              // 0.4 * 900
        #expect(r?.topLeftX == 270)           // (900 - 360) / 2, centered
        #expect(r?.height == 600)             // slot axis fills the height
    }

    @Test func emptyLanesCollapsePortrait() {
        let layout = StackingLayout(shape: .portraitDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        // In portrait the lane axis is Y. One used lane → 40% height,
        // vertically centered; fills the width.
        let r = layout.resolveRect(for: 1, in: portraitAvail, innerGap: 0)
        #expect(r?.width == 600)              // slot axis fills the width
        #expect(r?.height == 360)             // 0.4 * 900
        #expect(r?.topLeftY == 270)           // (900 - 360) / 2, centered
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
        // 3 rows at the default 0.4 → sum 1.2 > 1 → shrink to fill.
        #expect(abs((r1?.height ?? 0) - 300) < 0.001)
        #expect(abs((r1?.topLeftY ?? -1) - 0) < 0.001)
        #expect(abs((r3?.topLeftY ?? 0) - 600) < 0.001)
        #expect(abs((r1?.width ?? 0) - 600) < 0.001)  // full width since each row has 1 slot
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
        // Two USED lanes at the default width (0.4 each → total 0.8 < 1 →
        // centered). Span covers both → 0.8 * 900 = 720 px wide, centered
        // (offset 90), full 600 px height.
        #expect(r?.width == 720)
        #expect(r?.height == 600)
        #expect(r?.topLeftX == 90)
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
        // 3 lanes at default 0.4 → sum 1.2 > 1 → shrink to fill.
        #expect(abs((r1?.width ?? 0) - 600) < 0.001)
        #expect(abs((r1?.topLeftX ?? -1) - 0) < 0.001)
        #expect(abs((r2?.width ?? 0) - 300) < 0.001)
        #expect(abs((r2?.topLeftX ?? 0) - 600) < 0.001)
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

    // MARK: setLaneFraction (terminal fixed-width column)

    @Test func setLaneFractionSizesColumnToFractionLandscape() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        // Terminal lane (1) takes 1/3 of the width; lane 0 takes the rest.
        layout.setLaneFraction(1.0 / 3.0, lane: 1)
        let r0 = layout.resolveRect(for: 1, in: landscapeAvail, innerGap: 0)
        let r1 = layout.resolveRect(for: 2, in: landscapeAvail, innerGap: 0)
        #expect(abs((r1?.width ?? 0) - 300) < 0.001) // 1/3 of 900
        #expect(abs((r0?.width ?? 0) - 600) < 0.001) // 2/3 of 900
    }

    @Test func setLaneFractionKeepsOthersProportionLandscape() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        layout.place(3, at: .soleSlot(lane: 2))
        // Make lane 0 twice as wide as lane 1 before the terminal opens.
        layout.setLaneWeights([2, 1, 1, 1, 1, 1])
        // Terminal lane (2) takes 1/5; lanes 0 and 1 keep their 2:1 ratio
        // within the remaining 4/5.
        layout.setLaneFraction(1.0 / 5.0, lane: 2)
        let r0 = layout.resolveRect(for: 1, in: landscapeAvail, innerGap: 0)
        let r1 = layout.resolveRect(for: 2, in: landscapeAvail, innerGap: 0)
        let r2 = layout.resolveRect(for: 3, in: landscapeAvail, innerGap: 0)
        #expect(abs((r2?.width ?? 0) - 180) < 0.001)          // 1/5 of 900
        #expect(abs((r0?.width ?? 0) - 480) < 0.001)          // (2/3)*(4/5)*900
        #expect(abs((r1?.width ?? 0) - 240) < 0.001)          // (1/3)*(4/5)*900
        #expect(abs((r0?.width ?? 0) - 2 * (r1?.width ?? 0)) < 0.001) // ratio preserved
    }

    @Test func setLaneFractionNoopWithSingleUsedLane() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.setLaneFraction(1.0 / 3.0, lane: 0)
        // setLaneFraction is a no-op for a single used lane, so the lane
        // keeps the default column width (0.4) → 40% width, centered.
        let r = layout.resolveRect(for: 1, in: landscapeAvail, innerGap: 0)
        #expect(r?.width == 360)
        #expect(r?.topLeftX == 270)
    }

    // MARK: fit-or-center (naru carousel-disabled feel)

    @Test func loneAbsoluteWidthColumnCentersLandscape() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        // Absolute 1/3 width, alone → rendered at 1/3, horizontally centered.
        layout.setLaneAbsoluteWidth(1.0 / 3.0, lane: 0)
        let r = layout.resolveRect(for: 1, in: landscapeAvail, innerGap: 0)
        #expect(abs((r?.width ?? 0) - 300) < 0.001)               // 1/3 of 900
        #expect(abs((r?.topLeftX ?? 0) - 300) < 0.001)            // (900-300)/2 slack on the left
        #expect(abs((r?.height ?? 0) - 600) < 0.001)              // slot axis still fills height
    }

    @Test func twoDefaultColumnsCenterWithGap() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        // Two default (0.4) columns → total 0.8 < 1 → group centered with a
        // 90 px gap on each side (they do NOT stretch to fill).
        let r0 = layout.resolveRect(for: 1, in: landscapeAvail, innerGap: 0)
        let r1 = layout.resolveRect(for: 2, in: landscapeAvail, innerGap: 0)
        #expect(abs((r0?.width ?? 0) - 360) < 0.001)              // 0.4 * 900
        #expect(abs((r1?.width ?? 0) - 360) < 0.001)
        #expect(abs((r0?.topLeftX ?? -1) - 90) < 0.001)          // (900 - 720)/2
        #expect(abs((r1?.topLeftX ?? -1) - 450) < 0.001)         // 90 + 360
    }

    @Test func twoNarrowColumnsCenterAsGroupLandscape() {
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        // Two 1/4-width columns → total 1/2 < 1 → group centered.
        layout.setLaneAbsoluteWidth(0.25, lane: 0)
        layout.setLaneAbsoluteWidth(0.25, lane: 1)
        let r0 = layout.resolveRect(for: 1, in: landscapeAvail, innerGap: 0)
        let r1 = layout.resolveRect(for: 2, in: landscapeAvail, innerGap: 0)
        #expect(abs((r0?.width ?? 0) - 225) < 0.001)              // 1/4 of 900
        #expect(abs((r1?.width ?? 0) - 225) < 0.001)
        // Content 450 wide, centered → 225 slack each side; cols at 225 and 450.
        #expect(abs((r0?.topLeftX ?? 0) - 225) < 0.001)
        #expect(abs((r1?.topLeftX ?? 0) - 450) < 0.001)
    }

    @Test func narrowColumnCentersPortrait() {
        let layout = StackingLayout(shape: .portraitDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.setLaneAbsoluteWidth(0.5, lane: 0)
        // Portrait: lane axis = Y. 1/2 height, centered vertically; fills width.
        let r = layout.resolveRect(for: 1, in: portraitAvail, innerGap: 0)
        #expect(abs((r?.height ?? 0) - 450) < 0.001)              // 1/2 of 900
        #expect(abs((r?.topLeftY ?? 0) - 225) < 0.001)           // (900-450)/2
        #expect(abs((r?.width ?? 0) - 600) < 0.001)              // slot axis fills width
    }
}
