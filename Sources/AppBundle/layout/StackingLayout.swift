import AppKit
import Common

// MARK: - Orientation

/// Which axis is the "rigid" lane axis.
/// - `.landscape`: lanes run left→right (columns); slots within a lane run top→bottom (rows).
/// - `.portrait`: lanes run top→bottom (rows); slots within a lane run left→right (columns).
enum LayoutOrientation: String, Hashable, Codable {
    case landscape
    case portrait

    /// Pick orientation from a monitor rect. Square monitors map to landscape.
    static func forMonitor(width: CGFloat, height: CGFloat) -> LayoutOrientation {
        width >= height ? .landscape : .portrait
    }
}

// MARK: - LayoutShape

/// Rigid-axis cardinality. The model has `lanes` rigid lanes; slot counts
/// per lane are dynamic and derived from `StackingLayout.placements`.
struct LayoutShape: Equatable, Hashable, Codable {
    let orientation: LayoutOrientation
    let lanes: Int

    init(orientation: LayoutOrientation, lanes: Int) {
        precondition(lanes >= 1, "LayoutShape requires lanes >= 1, got \(lanes)")
        self.orientation = orientation
        self.lanes = lanes
    }

    static let landscapeDefault = LayoutShape(orientation: .landscape, lanes: 6)
    static let portraitDefault  = LayoutShape(orientation: .portrait,  lanes: 6)

    var middleLane: Int { lanes / 2 }
}

// MARK: - TileSpan

/// A rectangular span of cells in the grid: `lane0..lane1` along the
/// rigid lane axis, `slot0..slot1` along the flexible slot axis.
///
/// Naming is orientation-neutral: in landscape, lanes are columns and
/// slots are rows; in portrait, lanes are rows and slots are columns.
/// Single-lane spans (the common case) have `lane0 == lane1`. Multi-lane
/// spans cover a contiguous run of lanes — used by `stacking-resize` to
/// grow a window from 1 → 2 → 3 lanes as it moves toward an edge.
struct TileSpan: Equatable, Hashable {
    let lane0: Int
    let lane1: Int
    let slot0: Int
    let slot1: Int

    init(lane0: Int, lane1: Int, slot0: Int, slot1: Int) {
        precondition(lane0 <= lane1, "TileSpan: lane0 (\(lane0)) must be <= lane1 (\(lane1))")
        precondition(slot0 <= slot1, "TileSpan: slot0 (\(slot0)) must be <= slot1 (\(slot1))")
        self.lane0 = lane0
        self.lane1 = lane1
        self.slot0 = slot0
        self.slot1 = slot1
    }

    /// Backward-compatible single-lane initializer. Equivalent to
    /// `TileSpan(lane0: lane, lane1: lane, slot0:..., slot1:...)`.
    init(lane: Int, slot0: Int, slot1: Int) {
        self.init(lane0: lane, lane1: lane, slot0: slot0, slot1: slot1)
    }

    /// A single cell at `(lane, slot)`.
    static func single(lane: Int, slot: Int) -> TileSpan {
        TileSpan(lane0: lane, lane1: lane, slot0: slot, slot1: slot)
    }

    /// First slot of a fresh lane — used for "place this window alone in this lane."
    static func soleSlot(lane: Int) -> TileSpan {
        TileSpan(lane0: lane, lane1: lane, slot0: 0, slot1: 0)
    }

    /// Number of slots covered along the slot axis.
    var slotCount: Int { slot1 - slot0 + 1 }
    /// Number of lanes covered along the lane axis.
    var laneCount: Int { lane1 - lane0 + 1 }
    /// True iff this span covers a single lane.
    var isSingleLane: Bool { lane0 == lane1 }
}

// MARK: - StackingLayout

typealias WindowId = UInt32

/// Per-workspace layout. Rigid `lanes`; flexible per-lane slot counts and
/// weights. Replaces AeroSpace's tree of `TilingContainer`s.
final class StackingLayout {
    private(set) var shape: LayoutShape

    /// All tiled windows and their current span.
    private(set) var placements: [WindowId: TileSpan] = [:]

    /// Stacking order, back→front. Updated on focus and on placement.
    private(set) var zOrder: [WindowId] = []

    /// Per-lane slot weights, sized to `slotCount(in: lane)` lazily.
    /// Default weight is 1.0. Mutated by mouse-resize along the slot axis.
    private var slotWeights: [Int: [CGFloat]] = [:]

    init(shape: LayoutShape = .landscapeDefault) {
        self.shape = shape
    }

    var isEmpty: Bool { placements.isEmpty }

    // MARK: Mutation

    /// Place or move a window to `requested`. Slot indices may exceed
    /// the current `slotCount(in:)` — the lane grows on demand. Lane
    /// indices are clamped to `0..<shape.lanes` (the lane axis is
    /// rigid; bloom-style moves never go past it). The window is
    /// promoted to the top of `zOrder`.
    ///
    /// **Remembered-size rebalance.** When a *moved* window lands in
    /// a brand-new lane (insert-between / extract), the new lane gets
    /// the moved window's previous lane weight so its rendered column
    /// width is preserved. Surviving lanes keep their relative
    /// proportions and shrink so the total fills the screen. Same on
    /// the slot axis when a move lands in a fresh slot. Newly-opened
    /// windows (no `oldSpan`) get the default 1.0 weight, no rebalance.
    func place(_ windowId: WindowId, at requested: TileSpan) {
        guard requested.lane0 >= 0, requested.lane1 < shape.lanes else {
            remove(windowId)
            return
        }
        // Snapshot OLD state for the lane-axis remembered-size rebalance.
        let oldUsedLanes = Set(usedLanes)
        let oldLaneWeightsByIdx: [CGFloat] = (0..<shape.lanes).map { laneWeight(lane: $0) }
        let oldUsedSum = oldUsedLanes.reduce(0.0) { $0 + oldLaneWeightsByIdx[$1] }
        let oldSpan = placements[windowId]
        let oldFocusedLaneWeight: CGFloat? = oldSpan.map { oldLaneWeightsByIdx[$0.lane0] }
        let oldSlotCountInTargetLane = oldUsedLanes.contains(requested.lane0)
            ? slotCount(in: requested.lane0) : 0

        placements[windowId] = requested
        for lane in requested.lane0...requested.lane1 {
            ensureSlotWeightsCapacity(lane: lane, upTo: requested.slot1)
        }
        if let old = oldSpan {
            for lane in old.lane0...old.lane1 where lane < requested.lane0 || lane > requested.lane1 {
                compactLaneIfNeeded(lane)
            }
        }
        zOrder.removeAll { $0 == windowId }
        zOrder.append(windowId)

        // Lane-axis rebalance: moved into a brand-new lane.
        if !oldUsedLanes.contains(requested.lane0),
           let w = oldFocusedLaneWeight, w > 0, oldUsedSum > w
        {
            rebalanceForNewLaneRemembering(
                requested.lane0, oldFocusedWeight: w, oldUsedSum: oldUsedSum,
            )
        }
        // Slot-axis rebalance: moved into a fresh slot of an existing
        // lane. The new slot gets `1/N` of the lane height (landscape)
        // / row width (portrait); the other slots keep their relative
        // proportions and shrink to a combined `(N-1)/N` share.
        else if requested.slot0 >= oldSlotCountInTargetLane {
            rebalanceForNewSlot1OverN(in: requested.lane0, requested.slot0)
        }
        compactGaps()
        normalizeWeights()
    }

    /// Self-heal: enforce the `usedTotal/16` floor on every used lane
    /// and on the slot weights of each used lane. Without this a prior
    /// extreme grow can leave non-focused lanes / slots well below the
    /// ladder's minimum, making the grid feel "stuck" — many presses
    /// then needed to recover. Total per axis is conserved.
    func normalizeWeights() {
        let used = usedLanes
        if used.count >= 2 {
            var weights: [CGFloat] = (0..<shape.lanes).map { laneWeight(lane: $0) }
            let usedTotal = used.reduce(0.0) { $0 + weights[$1] }
            if usedTotal > 0 {
                let minPer = usedTotal / 16
                applyFloor(&weights, indices: used, minPer: minPer)
                if weights.allSatisfy({ $0 > 0 }) {
                    setLaneWeights(weights)
                }
            }
        }
        for lane in used {
            let slots = slotCount(in: lane)
            guard slots >= 2 else { continue }
            var w: [CGFloat] = (0..<slots).map { slotWeight(lane: lane, slot: $0) }
            let total = w.reduce(0, +)
            guard total > 0 else { continue }
            let minPer = total / 16
            applyFloor(&w, indices: Array(0..<slots), minPer: minPer)
            if w.allSatisfy({ $0 > 0 }) {
                setSlotWeights(lane: lane, weights: w)
            }
        }
    }

    private func applyFloor(_ weights: inout [CGFloat], indices: [Int], minPer: CGFloat) {
        var deficit: CGFloat = 0
        for i in indices where weights[i] < minPer {
            deficit += minPer - weights[i]
            weights[i] = minPer
        }
        guard deficit > 0 else { return }
        let donorAvailable = indices.reduce(0.0) { $0 + max(0, weights[$1] - minPer) }
        guard donorAvailable > 0 else { return }
        for i in indices where weights[i] > minPer {
            let avail = weights[i] - minPer
            weights[i] -= deficit * (avail / donorAvailable)
        }
    }

    /// New slot gets `1/N` of the lane axis; other slots in the lane
    /// keep their relative proportions and shrink to `(N-1)/N` total.
    private func rebalanceForNewSlot1OverN(in lane: Int, _ newSlotIdx: Int) {
        guard 0 <= lane, lane < shape.lanes else { return }
        let slots = slotCount(in: lane)
        guard slots >= 2, 0 <= newSlotIdx, newSlotIdx < slots else { return }
        var weights: [CGFloat] = (0..<slots).map { slotWeight(lane: lane, slot: $0) }
        let othersOldSum = (0..<slots).filter { $0 != newSlotIdx }.reduce(0.0) { $0 + weights[$1] }
        guard othersOldSum > 0 else { return }
        let n = CGFloat(slots)
        weights[newSlotIdx] = 1.0
        for s in 0..<slots where s != newSlotIdx {
            weights[s] = weights[s] * (n - 1) / othersOldSum
        }
        setSlotWeights(lane: lane, weights: weights)
    }

    /// Set the new lane's weight to the moved window's previous lane
    /// weight. Surviving used lanes keep their relative proportions and
    /// scale by `(oldUsedSum − oldFocusedWeight) / sum(survivor old
    /// weights)` so the visible partition still sums to the available
    /// width.
    private func rebalanceForNewLaneRemembering(
        _ newLaneIdx: Int,
        oldFocusedWeight w: CGFloat,
        oldUsedSum S: CGFloat,
    ) {
        let used = usedLanes
        guard used.count >= 2, 0 <= newLaneIdx, newLaneIdx < shape.lanes else { return }
        guard w > 0, S > w else { return }
        var weights: [CGFloat] = (0..<shape.lanes).map { laneWeight(lane: $0) }
        let survivors = used.filter { $0 != newLaneIdx }
        let survivorsOldSum = survivors.reduce(0.0) { $0 + weights[$1] }
        guard survivorsOldSum > 0 else { return }
        let scale = (S - w) / survivorsOldSum
        weights[newLaneIdx] = w
        for l in survivors {
            weights[l] = weights[l] * scale
        }
        setLaneWeights(weights)
    }

    /// Grow `lane`'s weight so its rendered main-axis size hits at
    /// least `requiredPx`. Other used lanes shrink proportionally.
    /// Each donor stays above `usedTotal/16` so the resize ladder's
    /// minimum is preserved. No-op when there's only one used lane.
    /// Used by the forced-resize path for windows that own their tile.
    @discardableResult
    func growLaneToFit(requiredPx: CGFloat, lane: Int, totalUsablePx: CGFloat) -> Bool {
        let used = usedLanes
        guard used.count >= 2, lane >= 0, lane < shape.lanes, totalUsablePx > 0 else { return false }
        var weights: [CGFloat] = (0..<shape.lanes).map { laneWeight(lane: $0) }
        let usedTotal = used.reduce(0.0) { $0 + weights[$1] }
        guard usedTotal > 0 else { return false }
        let pxPerWeight = totalUsablePx / usedTotal
        let currentPx = weights[lane] * pxPerWeight
        if currentPx + 1 >= requiredPx { return false }
        let minOther: CGFloat = usedTotal / 16
        let maxAllowed = usedTotal - CGFloat(used.count - 1) * minOther
        let newW = min(requiredPx / pxPerWeight, maxAllowed)
        if newW <= weights[lane] { return false }
        let delta = newW - weights[lane]
        let sumOthers = usedTotal - weights[lane]
        guard sumOthers > 0 else { return false }
        weights[lane] = newW
        for l in used where l != lane {
            weights[l] -= delta * (weights[l] / sumOthers)
        }
        if weights.contains(where: { $0 <= 0 }) { return false }
        setLaneWeights(weights)
        return true
    }

    /// Same idea on the slot axis within `lane`.
    @discardableResult
    func growSlotToFit(requiredPx: CGFloat, lane: Int, slot: Int, totalUsablePx: CGFloat) -> Bool {
        guard 0 <= lane, lane < shape.lanes, totalUsablePx > 0 else { return false }
        let slots = slotCount(in: lane)
        guard slots >= 2, slot >= 0, slot < slots else { return false }
        var weights: [CGFloat] = (0..<slots).map { slotWeight(lane: lane, slot: $0) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return false }
        let pxPerWeight = totalUsablePx / total
        let currentPx = weights[slot] * pxPerWeight
        if currentPx + 1 >= requiredPx { return false }
        let minOther: CGFloat = total / 16
        let maxAllowed = total - CGFloat(slots - 1) * minOther
        let newW = min(requiredPx / pxPerWeight, maxAllowed)
        if newW <= weights[slot] { return false }
        let delta = newW - weights[slot]
        let sumOthers = total - weights[slot]
        guard sumOthers > 0 else { return false }
        weights[slot] = newW
        for s in 0..<slots where s != slot {
            weights[s] -= delta * (weights[s] / sumOthers)
        }
        if weights.contains(where: { $0 <= 0 }) { return false }
        setSlotWeights(lane: lane, weights: weights)
        return true
    }

    @discardableResult
    func remove(_ windowId: WindowId) -> TileSpan? {
        guard let span = placements.removeValue(forKey: windowId) else { return nil }
        zOrder.removeAll { $0 == windowId }
        for lane in span.lane0...span.lane1 { compactLaneIfNeeded(lane) }
        compactGaps()
        return span
    }

    /// Squeeze out empty cells: shift used lanes leftward so they're
    /// contiguous from index 0, and renumber slots within each lane to
    /// be contiguous from 0. `shape.lanes` stays put — trailing empties
    /// remain available for `appendLane()` and the rigid-grid feel is
    /// preserved. Slot and lane weights migrate with their indices.
    /// Single-lane spans only — multi-lane spans use `lane0`'s slot map.
    private func compactGaps() {
        let oldUsed = usedLanes
        if oldUsed.isEmpty {
            slotWeights.removeAll()
            return
        }
        // Lane renumber: shift leftward to fill gaps.
        var laneMap: [Int: Int] = [:]
        for (newL, oldL) in oldUsed.enumerated() { laneMap[oldL] = newL }
        let laneShift = oldUsed.enumerated().contains { $0.offset != $0.element }
        // Per-lane slot renumber maps + new weights.
        var slotMaps: [Int: [Int: Int]] = [:]
        var newSlotWeights: [Int: [CGFloat]] = [:]
        var slotShift = false
        for (newL, oldL) in oldUsed.enumerated() {
            var usedSlots = Set<Int>()
            for span in placements.values where span.lane0 <= oldL && oldL <= span.lane1 {
                for s in span.slot0...span.slot1 { usedSlots.insert(s) }
            }
            let sorted = usedSlots.sorted()
            var sm: [Int: Int] = [:]
            var weights: [CGFloat] = []
            for (newS, oldS) in sorted.enumerated() {
                sm[oldS] = newS
                if newS != oldS { slotShift = true }
                weights.append(slotWeight(lane: oldL, slot: oldS))
            }
            slotMaps[newL] = sm
            newSlotWeights[newL] = weights
        }
        guard laneShift || slotShift else { return } // already tight
        // Renumber placements.
        var newPlacements: [WindowId: TileSpan] = [:]
        for (wid, span) in placements {
            guard let nl0 = laneMap[span.lane0], let nl1 = laneMap[span.lane1],
                  let sm = slotMaps[nl0],
                  let ns0 = sm[span.slot0], let ns1 = sm[span.slot1]
            else { continue }
            newPlacements[wid] = TileSpan(lane0: nl0, lane1: nl1, slot0: ns0, slot1: ns1)
        }
        // Renumber lane weights — keep shape.lanes count, pad trailing with 1.0.
        if let oldLW = _laneWeights {
            var nlw: [CGFloat] = []
            for oldL in oldUsed {
                nlw.append(oldL < oldLW.count ? oldLW[oldL] : 1.0)
            }
            while nlw.count < shape.lanes { nlw.append(1.0) }
            _laneWeights = nlw
        }
        placements = newPlacements
        slotWeights = newSlotWeights
        // shape.lanes UNCHANGED — trailing empties are part of the rigid grid.
    }

    func promote(_ windowId: WindowId) {
        guard placements[windowId] != nil else { return }
        zOrder.removeAll { $0 == windowId }
        zOrder.append(windowId)
    }

    /// Swap two columns wholesale: every placement currently in `laneA`
    /// moves to `laneB` (and vice-versa), `laneWeights` swap, and the
    /// per-lane slot weights swap so each column keeps its own row
    /// partition. Multi-lane spans that overlap exactly one of the
    /// swapped lanes pivot accordingly; spans that straddle both lanes
    /// are left unchanged (rare in the bloom model).
    func swapLanes(_ laneA: Int, _ laneB: Int) {
        guard laneA != laneB,
              0 <= laneA, laneA < shape.lanes,
              0 <= laneB, laneB < shape.lanes else { return }
        var newPlacements: [WindowId: TileSpan] = [:]
        for (wid, span) in placements {
            let nl0 = span.lane0 == laneA ? laneB : (span.lane0 == laneB ? laneA : span.lane0)
            let nl1 = span.lane1 == laneA ? laneB : (span.lane1 == laneB ? laneA : span.lane1)
            if nl0 <= nl1 {
                newPlacements[wid] = TileSpan(lane0: nl0, lane1: nl1, slot0: span.slot0, slot1: span.slot1)
            } else {
                newPlacements[wid] = span
            }
        }
        placements = newPlacements
        // Swap lane weights.
        var weights: [CGFloat] = []
        for l in 0..<shape.lanes { weights.append(laneWeight(lane: l)) }
        weights.swapAt(laneA, laneB)
        _laneWeights = weights
        // Swap per-lane slot weights so each column keeps its own row partition.
        let wA = slotWeights[laneA]
        let wB = slotWeights[laneB]
        slotWeights[laneA] = wB
        slotWeights[laneB] = wA
    }

    /// Append a brand new lane at the trailing edge, growing
    /// `shape.lanes` by 1. Returns the new lane's index. Lane weights
    /// for the new lane default to 1.0 (the implicit fallback).
    func appendLane() -> Int {
        let newIdx = shape.lanes
        shape = LayoutShape(orientation: shape.orientation, lanes: shape.lanes + 1)
        return newIdx
    }

    /// Insert a new lane at index 0, shifting every existing placement,
    /// slot-weight key, and lane-weight entry one position to the right.
    func insertLaneAtFront() { insertLane(at: 0) }

    /// Insert a new lane at `idx`. Placements with `lane0 >= idx` shift
    /// right by 1; slot-weight keys and lane-weight entries shift to
    /// match. Used by `stacking-move` for the "extract between source and
    /// neighbour" step of the two-step inward move.
    func insertLane(at idx: Int) {
        guard idx >= 0, idx <= shape.lanes else { return }
        var newPlacements: [WindowId: TileSpan] = [:]
        for (wid, span) in placements {
            if span.lane0 >= idx {
                newPlacements[wid] = TileSpan(
                    lane0: span.lane0 + 1, lane1: span.lane1 + 1,
                    slot0: span.slot0, slot1: span.slot1,
                )
            } else {
                newPlacements[wid] = span
            }
        }
        placements = newPlacements
        var newSlotWeights: [Int: [CGFloat]] = [:]
        for (lane, w) in slotWeights {
            newSlotWeights[lane >= idx ? lane + 1 : lane] = w
        }
        slotWeights = newSlotWeights
        if var lw = _laneWeights, idx <= lw.count {
            lw.insert(1.0, at: idx)
            _laneWeights = lw
        }
        shape = LayoutShape(orientation: shape.orientation, lanes: shape.lanes + 1)
    }

    /// Insert a new slot at index 0 within `lane`, shifting every
    /// placement that touches the lane down by 1 along the slot axis.
    func insertSlotAtFront(in lane: Int) { insertSlot(in: lane, at: 0) }

    /// Insert a new slot at `slotIdx` within `lane`. Placements in the
    /// lane at slots `>= slotIdx` shift down by 1; slot weights gain a
    /// new 1.0 entry at `slotIdx`. Used by `stacking-move` when merging a
    /// dragged-in window between existing rows of the target column.
    func insertSlot(in lane: Int, at slotIdx: Int) {
        guard 0 <= lane, lane < shape.lanes, slotIdx >= 0 else { return }
        var newPlacements: [WindowId: TileSpan] = [:]
        for (wid, span) in placements {
            if span.lane0 <= lane && lane <= span.lane1 && span.slot0 >= slotIdx {
                newPlacements[wid] = TileSpan(
                    lane0: span.lane0, lane1: span.lane1,
                    slot0: span.slot0 + 1, slot1: span.slot1 + 1,
                )
            } else {
                newPlacements[wid] = span
            }
        }
        placements = newPlacements
        var sw = slotWeights[lane] ?? []
        let cap = min(slotIdx, sw.count)
        sw.insert(1.0, at: cap)
        slotWeights[lane] = sw
    }

    /// Pick the OCCUPIED slot in `lane` whose centre is closest to
    /// `point`'s slot-axis coordinate (Y in landscape, X in portrait).
    /// Used by `stacking-move`'s OVERLAP action to land focused on top of
    /// the existing window the user is "aiming at" instead of always
    /// using slot 0. Returns nil when the lane is empty.
    func nearestOccupiedSlot(in lane: Int, to point: CGPoint, available: Rect, innerGap: CGFloat = 0) -> Int? {
        let occupied = Set(
            placements.values
                .filter { $0.lane0 <= lane && lane <= $0.lane1 }
                .flatMap { $0.slot0...$0.slot1 }
        )
        if occupied.isEmpty { return nil }
        let slots = slotCount(in: lane)
        guard slots > 0 else { return nil }
        var weights: [CGFloat] = []
        for s in 0..<slots { weights.append(slotWeight(lane: lane, slot: s)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return occupied.sorted().first }
        let landscape = shape.orientation == .landscape
        let pt = landscape ? point.y : point.x
        let start = landscape ? available.topLeftY : available.topLeftX
        let extent = landscape ? available.height : available.width
        let usable = extent - max(0, CGFloat(slots - 1)) * innerGap
        var bestSlot: Int? = nil
        var bestDist: CGFloat = .infinity
        var c = start
        for s in 0..<slots {
            let w = weights[s] / total * usable
            if occupied.contains(s) {
                let d = abs(pt - (c + w / 2))
                if d < bestDist { bestDist = d; bestSlot = s }
            }
            c += w + innerGap
        }
        return bestSlot
    }

    /// Pick the slot index in `lane` that best matches a vertical (or
    /// horizontal in portrait) point. Used by `stacking-move` to decide
    /// above-vs-below when a window merges into a target column.
    /// Returns `0..<slotCount(in: lane)` for "insert before slot N",
    /// or `slotCount(in: lane)` for "append at the end".
    func insertionSlot(in lane: Int, at point: CGPoint, available: Rect, innerGap: CGFloat = 0) -> Int {
        let slots = slotCount(in: lane)
        if slots == 0 { return 0 }
        var weights: [CGFloat] = []
        for s in 0..<slots { weights.append(slotWeight(lane: lane, slot: s)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        let landscape = shape.orientation == .landscape
        let pt = landscape ? point.y : point.x
        let start = landscape ? available.topLeftY : available.topLeftX
        let extent = landscape ? available.height : available.width
        let usable = extent - max(0, CGFloat(slots - 1)) * innerGap
        var c = start
        for s in 0..<slots {
            let w = weights[s] / total * usable
            if pt < c + w / 2 { return s }
            c += w + innerGap
        }
        return slots
    }

    /// Swap two rows within a single lane: every placement in `lane`
    /// touching `slotA` moves to `slotB` (and vice-versa), and the
    /// lane's slot weights swap so each row keeps its size.
    func swapSlots(in lane: Int, _ slotA: Int, _ slotB: Int) {
        guard slotA != slotB, 0 <= lane, lane < shape.lanes else { return }
        var newPlacements: [WindowId: TileSpan] = [:]
        for (wid, span) in placements {
            if span.lane0 <= lane && lane <= span.lane1 {
                let ns0 = span.slot0 == slotA ? slotB : (span.slot0 == slotB ? slotA : span.slot0)
                let ns1 = span.slot1 == slotA ? slotB : (span.slot1 == slotB ? slotA : span.slot1)
                if ns0 <= ns1 {
                    newPlacements[wid] = TileSpan(lane0: span.lane0, lane1: span.lane1, slot0: ns0, slot1: ns1)
                } else {
                    newPlacements[wid] = span
                }
            } else {
                newPlacements[wid] = span
            }
        }
        placements = newPlacements
        // Swap slot weights for this lane.
        var sw = slotWeights[lane] ?? []
        let needed = max(slotA, slotB) + 1
        while sw.count < needed { sw.append(1.0) }
        sw.swapAt(slotA, slotB)
        slotWeights[lane] = sw
    }

    /// Switch shape (e.g. monitor rotated, or user changed lane count).
    /// Returns evicted windows (those whose lane range no longer fits).
    func reshape(to newShape: LayoutShape) -> [WindowId] {
        if newShape == shape { return [] }
        var evicted: [WindowId] = []
        var rebuilt: [WindowId: TileSpan] = [:]
        for (wid, span) in placements {
            if span.lane1 < newShape.lanes {
                rebuilt[wid] = span
            } else {
                evicted.append(wid)
            }
        }
        var rebuiltWeights: [Int: [CGFloat]] = [:]
        for (lane, w) in slotWeights where lane < newShape.lanes { rebuiltWeights[lane] = w }
        shape = newShape
        placements = rebuilt
        slotWeights = rebuiltWeights
        zOrder.removeAll { evicted.contains($0) }
        return evicted
    }

    // MARK: Queries

    /// Lanes containing at least one window. Sorted ascending. A multi-lane
    /// span contributes every lane it covers.
    var usedLanes: [Int] {
        var s: Set<Int> = []
        for span in placements.values {
            for lane in span.lane0...span.lane1 { s.insert(lane) }
        }
        return s.sorted()
    }

    /// Lanes with no windows.
    var emptyLanes: [Int] {
        let used = Set(usedLanes)
        return (0..<shape.lanes).filter { !used.contains($0) }
    }

    /// Number of slots in a lane = `max(slot1) + 1` over placements that
    /// touch this lane (single- or multi-lane).
    func slotCount(in lane: Int) -> Int {
        var maxSlot = -1
        for span in placements.values where span.lane0 <= lane && lane <= span.lane1 {
            if span.slot1 > maxSlot { maxSlot = span.slot1 }
        }
        return maxSlot + 1
    }

    func windows(in lane: Int) -> [WindowId] {
        placements
            .filter { $0.value.lane0 <= lane && lane <= $0.value.lane1 }
            .sorted { $0.value.slot0 < $1.value.slot0 }
            .map(\.key)
    }

    // MARK: Lane weights

    /// Per-lane weight along the LANE axis (column widths in landscape,
    /// row heights in portrait). Default 1.0 each — equal partition.
    /// Mutated by mouse-resize on the lane-axis edges (left/right in
    /// landscape, top/bottom in portrait), AeroSpace-style.
    /// Stored separately from `slotWeights` because slots are per-lane;
    /// these weights are workspace-level.
    private var _laneWeights: [CGFloat]?

    /// Window IDs auto-detected as non-resizable (app refused setAxFrame).
    /// These are removed from the grid and floated. Session-only — a
    /// reopened window goes through registration again (and may be
    /// auto-floated again if it's still non-resizable).
    var nonResizableWindows: Set<WindowId> = []

    /// Window IDs that successfully accepted a setAxFrame within
    /// tolerance. Cached so the post-layout verification AX query only
    /// runs ONCE per window, not on every refresh.
    var verifiedResizableWindows: Set<WindowId> = []

    /// Minimum content size observed for a window — populated by the
    /// post-`setAxFrame` fit-check whenever an app refused to shrink.
    /// On subsequent layouts the pre-pass uses these to size the tile
    /// correctly the first time so there's no visible "set small →
    /// grow" jump. Only applied when the window is alone in its lane
    /// (single window per tile) — overlapping or stacked layouts use
    /// best-effort sizing instead.
    var observedMinSizes: [WindowId: CGSize] = [:]

    func laneWeight(lane: Int) -> CGFloat {
        guard lane >= 0, lane < shape.lanes else { return 1.0 }
        return _laneWeights?[lane] ?? 1.0
    }

    func setLaneWeights(_ weights: [CGFloat]) {
        guard weights.count == shape.lanes, weights.allSatisfy({ $0 > 0 }) else { return }
        _laneWeights = weights
    }

    // MARK: Slot weights

    func slotWeight(lane: Int, slot: Int) -> CGFloat {
        let w = slotWeights[lane] ?? []
        return slot >= 0 && slot < w.count ? w[slot] : 1.0
    }

    func setSlotWeights(lane: Int, weights: [CGFloat]) {
        guard lane >= 0 && lane < shape.lanes, weights.allSatisfy({ $0 > 0 }) else { return }
        slotWeights[lane] = weights
    }

    private func ensureSlotWeightsCapacity(lane: Int, upTo slot: Int) {
        var w = slotWeights[lane] ?? []
        while w.count <= slot { w.append(1.0) }
        slotWeights[lane] = w
    }

    private func compactLaneIfNeeded(_ lane: Int) {
        let needed = slotCount(in: lane)
        if needed == 0 {
            slotWeights.removeValue(forKey: lane)
        } else if var w = slotWeights[lane], w.count > needed {
            w.removeLast(w.count - needed)
            slotWeights[lane] = w
        }
    }
}

// MARK: - Geometry (orientation-aware)

extension StackingLayout {
    /// Resolve a window's screen-space rect. `available` is post-outer-gap
    /// workspace rect; `innerGap` separates adjacent USED lanes and
    /// adjacent slots within a lane.
    ///
    /// Empty lanes collapse: only `usedLanes` are rendered. Used lanes
    /// are partitioned by per-lane weights (default 1.0 = equal). The
    /// AeroSpace-style mouse-resize on lane-axis edges mutates these
    /// per-lane weights via `setLaneWeights`.
    func resolveRect(
        for windowId: WindowId,
        in available: Rect,
        innerGap: CGFloat = 0
    ) -> Rect? {
        guard let span = placements[windowId] else { return nil }
        let used = usedLanes
        guard !used.isEmpty else { return nil }
        // A multi-lane span is anchored to its low/high lane in the visible
        // partition. Both must be in `used` (they are by definition — they
        // contain this very window).
        guard let visIdx0 = used.firstIndex(of: span.lane0),
              let visIdx1 = used.firstIndex(of: span.lane1) else { return nil }

        // Lane axis: weighted partition over USED lanes only.
        let nLanes = CGFloat(used.count)
        let totalLaneGap = max(0, nLanes - 1) * innerGap
        let usedLaneWeights = used.map { laneWeight(lane: $0) }
        let totalLaneWeight = usedLaneWeights.reduce(0, +)
        guard totalLaneWeight > 0 else { return nil }

        // Slot axis: weighted partition of `lane0` (canonical for multi-lane
        // spans). All covered lanes are grown to at least `slot1+1` slots
        // by `place(...)`, so `lane0`'s weights are well-defined.
        let slots = slotCount(in: span.lane0)
        guard slots > 0, span.slot0 < slots, span.slot1 < slots else { return nil }
        var weights: [CGFloat] = []
        for s in 0..<slots { weights.append(slotWeight(lane: span.lane0, slot: s)) }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return nil }
        let totalSlotGap = max(0, CGFloat(slots - 1)) * innerGap

        // Lane-axis prefix (weights up to span start) and extent (weights
        // covered by the span). For single-lane spans this collapses to
        // `extent = usedLaneWeights[visIdx0]`.
        var lanePrefix: CGFloat = 0
        for i in 0..<visIdx0 { lanePrefix += usedLaneWeights[i] }
        var laneExtent: CGFloat = 0
        for i in visIdx0...visIdx1 { laneExtent += usedLaneWeights[i] }

        switch shape.orientation {
            case .landscape:
                // Lane axis = X, slot axis = Y.
                let usableW = available.width - totalLaneGap
                let usableH = available.height - totalSlotGap
                let x = available.topLeftX
                    + lanePrefix / totalLaneWeight * usableW
                    + CGFloat(visIdx0) * innerGap
                let laneSpanW = laneExtent / totalLaneWeight * usableW
                    + CGFloat(visIdx1 - visIdx0) * innerGap
                var y0 = available.topLeftY
                for s in 0..<span.slot0 { y0 += weights[s] / totalWeight * usableH + innerGap }
                var spanH: CGFloat = 0
                for s in span.slot0...span.slot1 { spanH += weights[s] }
                let h = spanH / totalWeight * usableH + max(0, CGFloat(span.slot1 - span.slot0)) * innerGap
                return Rect(topLeftX: x, topLeftY: y0, width: laneSpanW, height: h)
            case .portrait:
                // Lane axis = Y, slot axis = X.
                let usableH = available.height - totalLaneGap
                let usableW = available.width - totalSlotGap
                let y = available.topLeftY
                    + lanePrefix / totalLaneWeight * usableH
                    + CGFloat(visIdx0) * innerGap
                let laneSpanH = laneExtent / totalLaneWeight * usableH
                    + CGFloat(visIdx1 - visIdx0) * innerGap
                var x0 = available.topLeftX
                for s in 0..<span.slot0 { x0 += weights[s] / totalWeight * usableW + innerGap }
                var spanW: CGFloat = 0
                for s in span.slot0...span.slot1 { spanW += weights[s] }
                let w = spanW / totalWeight * usableW + max(0, CGFloat(span.slot1 - span.slot0)) * innerGap
                return Rect(topLeftX: x0, topLeftY: y, width: w, height: laneSpanH)
        }
    }
}

// MARK: - Hit testing

extension StackingLayout {
    /// Find the (lane, slot) cell containing `point`, given the
    /// workspace's available rect. Used for drag-and-drop snap.
    /// Returns nil when the grid is empty.
    func cellAt(point: CGPoint, in available: Rect, innerGap: CGFloat = 0) -> (lane: Int, slot: Int)? {
        let used = usedLanes
        guard !used.isEmpty else { return nil }
        let totalLaneGap = max(0, CGFloat(used.count - 1)) * innerGap
        let usedLW = used.map { laneWeight(lane: $0) }
        let totalLW = usedLW.reduce(0, +)
        guard totalLW > 0 else { return nil }

        let mainPt: CGFloat, secPt: CGFloat
        let mainStart: CGFloat, secStart: CGFloat
        let usableMain: CGFloat, usableSecAxis: CGFloat
        switch shape.orientation {
            case .landscape:
                mainPt = point.x; secPt = point.y
                mainStart = available.topLeftX; secStart = available.topLeftY
                usableMain = available.width - totalLaneGap
                usableSecAxis = available.height
            case .portrait:
                mainPt = point.y; secPt = point.x
                mainStart = available.topLeftY; secStart = available.topLeftX
                usableMain = available.height - totalLaneGap
                usableSecAxis = available.width
        }
        // Walk lane partition.
        var c = mainStart
        var lane = used.last ?? 0
        for (i, l) in used.enumerated() {
            let w = usedLW[i] / totalLW * usableMain
            if mainPt < c + w { lane = l; break }
            c += w + innerGap
        }
        // Walk slot partition within that lane.
        let slots = slotCount(in: lane)
        guard slots > 0 else { return (lane, 0) }
        var sw: [CGFloat] = []
        for s in 0..<slots { sw.append(slotWeight(lane: lane, slot: s)) }
        let totalSW = sw.reduce(0, +)
        let totalSlotGap = max(0, CGFloat(slots - 1)) * innerGap
        let usableSec = usableSecAxis - totalSlotGap
        var c2 = secStart
        var slot = slots - 1
        for s in 0..<slots {
            let w = sw[s] / totalSW * usableSec
            if secPt < c2 + w { slot = s; break }
            c2 += w + innerGap
        }
        return (lane, slot)
    }
}

// MARK: - Placement heuristic

extension StackingLayout {
    /// Decide where a new window goes:
    ///   - empty workspace → lane 0, slot 0.
    ///   - exactly one used lane → split into a fresh lane (a new column
    ///     in landscape, a new row in portrait) so we move from a single-
    ///     stack layout into a side-by-side one.
    ///   - 2+ used lanes → stack as a new bottom row in the focused
    ///     window's column. If there's no focused tiled window, stack in
    ///     the rightmost used lane.
    /// Beyond the single-lane case, new columns stay user-driven
    /// (`stacking-place`, drag-and-drop, or the extend-on-edge gesture).
    func placementForNewWindow(focusedLane: Int? = nil) -> TileSpan {
        let used = usedLanes
        if used.isEmpty { return .soleSlot(lane: 0) }
        if used.count == 1 {
            let onlyUsed = used[0]
            let nextEmpty = onlyUsed + 1 < shape.lanes
                ? onlyUsed + 1
                : appendLane()
            return .soleSlot(lane: nextEmpty)
        }
        let targetLane = focusedLane ?? used.last!
        let newSlot = slotCount(in: targetLane)
        return .single(lane: targetLane, slot: newSlot)
    }
}
