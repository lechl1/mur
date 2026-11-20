@testable import AppBundle
import AppKit
import Common
import Testing

/// A moved window keeps its size: its own column at its old width on another
/// workspace, its old row height (at most an equal share) in another column.
@Suite("StackingLayout moved-window size")
struct StackingMovedWindowSizeTest {
    private let avail = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)

    private func layout(widths: [CGFloat]) -> StackingLayout {
        let l = StackingLayout(shape: .landscapeDefault)
        for (i, _) in widths.enumerated() { l.place(WindowId(100 + i), at: .soleSlot(lane: i)) }
        var w = (0 ..< l.shape.lanes).map { l.laneWeight(lane: $0) }
        for (i, x) in widths.enumerated() { w[i] = x }
        l.setLaneWeights(w)
        return l
    }

    @Test func ownColumnShrinksTheOthersProportionally() {
        let l = layout(widths: [0.6, 0.4])
        l.placeInOwnLane(1, at: 2, width: 0.5)
        #expect(l.placements[1] == .soleSlot(lane: 2))
        #expect(abs(l.laneWeight(lane: 2) - 0.5) < 1e-9)
        #expect(abs(l.laneWeight(lane: 0) - 0.3) < 1e-9)
        #expect(abs(l.laneWeight(lane: 1) - 0.2) < 1e-9)
    }

    @Test func ownColumnLeavesAStripThatStillFitsAlone() {
        let l = layout(widths: [0.3])
        l.placeInOwnLane(1, at: 0, width: 0.4)
        #expect(l.placements[1] == .soleSlot(lane: 0))
        #expect(abs(l.laneWeight(lane: 0) - 0.4) < 1e-9)
        #expect(abs(l.laneWeight(lane: 1) - 0.3) < 1e-9)
        // It renders at its width: 400pt of 1000.
        #expect(abs((l.resolveRect(for: 1, in: avail)?.width ?? 0) - 400) < 1e-6)
    }

    @Test func ownColumnOnAnEmptyWorkspaceIsCentredAtItsWidth() {
        let l = StackingLayout(shape: .landscapeDefault)
        l.placeInOwnLane(1, at: 0, width: 0.7)
        let r = l.resolveRect(for: 1, in: avail)
        #expect(abs((r?.width ?? 0) - 700) < 1e-6)
        #expect(abs((r?.topLeftX ?? 0) - 150) < 1e-6)
    }

    @Test func aWindowAsWideAsTheScreenLeavesTheOthersTheirMinimum() {
        let l = layout(widths: [0.5, 0.5])
        l.placeInOwnLane(1, at: 1, width: 1.0)
        #expect(l.placements[1] == .soleSlot(lane: 1))
        #expect(l.laneWeight(lane: 0) >= StackingResize.minLaneWidth - 1e-9)
        #expect(l.laneWeight(lane: 2) >= StackingResize.minLaneWidth - 1e-9)
        #expect(abs(l.laneWeight(lane: 1) - (1 - 2 * StackingResize.minLaneWidth)) < 1e-9)
    }

    @Test func insertionIndexFollowsTheEntryPoint() {
        let l = layout(widths: [0.5, 0.5])
        #expect(l.laneInsertionIndex(at: CGPoint(x: 1, y: 300), in: avail) == 0)
        #expect(l.laneInsertionIndex(at: CGPoint(x: 400, y: 300), in: avail) == 1)
        #expect(l.laneInsertionIndex(at: CGPoint(x: 999, y: 300), in: avail) == 2)
    }

    @Test func portraitKeepsTheRowHeight() {
        let l = StackingLayout(shape: .portraitDefault)
        l.place(100, at: .soleSlot(lane: 0))
        l.place(101, at: .soleSlot(lane: 1))
        l.setLaneWeights([0.5, 0.5] + Array(repeating: 0.4, count: l.shape.lanes - 2))
        l.placeInOwnLane(1, at: 0, width: 0.25)
        let portrait = Rect(topLeftX: 0, topLeftY: 0, width: 600, height: 1000)
        #expect(abs((l.resolveRect(for: 1, in: portrait)?.height ?? 0) - 250) < 1e-6)
    }

    @Test func rowShareIsKeptWhenSmallerThanAnEqualShare() {
        let l = StackingLayout(shape: .landscapeDefault)
        for s in 0 ..< 3 { l.place(WindowId(s), at: .single(lane: 0, slot: s)) }
        l.keepSlotShare(0.2, lane: 0, slot: 1)
        let w = (0 ..< 3).map { l.slotWeight(lane: 0, slot: $0) }
        #expect(abs(w[1] / w.reduce(0, +) - 0.2) < 1e-9)
        // The others keep their proportions.
        #expect(abs(w[0] - w[2]) < 1e-9)
    }

    @Test func rowShareIsCappedAtAnEqualShare() {
        let l = StackingLayout(shape: .landscapeDefault)
        for s in 0 ..< 3 { l.place(WindowId(s), at: .single(lane: 0, slot: s)) }
        l.keepSlotShare(1.0, lane: 0, slot: 2)
        let w = (0 ..< 3).map { l.slotWeight(lane: 0, slot: $0) }
        #expect(abs(w[2] / w.reduce(0, +) - 1.0 / 3) < 1e-9)
    }
}
