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
/// per lane are dynamic and derived from `GridLayout.placements`.
struct LayoutShape: Equatable, Hashable, Codable {
    let orientation: LayoutOrientation
    let lanes: Int

    init(orientation: LayoutOrientation, lanes: Int) {
        precondition(lanes >= 1, "LayoutShape requires lanes >= 1, got \(lanes)")
        self.orientation = orientation
        self.lanes = lanes
    }

    static let landscapeDefault = LayoutShape(orientation: .landscape, lanes: 3)
    static let portraitDefault  = LayoutShape(orientation: .portrait,  lanes: 3)

    var middleLane: Int { lanes / 2 }
}

// MARK: - TileSpan

/// A contiguous run of slots in a single lane.
///
/// Naming is orientation-neutral: in landscape, `lane` is a column and
/// `slot0..slot1` are rows within that column; in portrait, `lane` is a
/// row and `slot0..slot1` are columns within that row.
struct TileSpan: Equatable, Hashable {
    let lane: Int
    let slot0: Int
    let slot1: Int

    init(lane: Int, slot0: Int, slot1: Int) {
        precondition(slot0 <= slot1, "TileSpan: slot0 (\(slot0)) must be <= slot1 (\(slot1))")
        self.lane = lane
        self.slot0 = slot0
        self.slot1 = slot1
    }

    /// A single slot at `(lane, slot)`.
    static func single(lane: Int, slot: Int) -> TileSpan {
        TileSpan(lane: lane, slot0: slot, slot1: slot)
    }

    /// First slot of a fresh lane — used for "place this window alone in this lane."
    static func soleSlot(lane: Int) -> TileSpan {
        TileSpan(lane: lane, slot0: 0, slot1: 0)
    }

    var slotCount: Int { slot1 - slot0 + 1 }
}

// MARK: - GridLayout

typealias WindowId = UInt32

/// Per-workspace layout. Rigid `lanes`; flexible per-lane slot counts and
/// weights. Replaces AeroSpace's tree of `TilingContainer`s.
final class GridLayout {
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

    /// Place or move a window to `requested`. Slot indices below may exceed
    /// the current `slotCount(in:)` — this implicitly grows the lane. The
    /// window is promoted to the top of `zOrder`.
    func place(_ windowId: WindowId, at requested: TileSpan) {
        guard requested.lane >= 0 && requested.lane < shape.lanes else {
            remove(windowId)
            return
        }
        let oldLane = placements[windowId]?.lane
        placements[windowId] = requested
        ensureSlotWeightsCapacity(lane: requested.lane, upTo: requested.slot1)
        if let old = oldLane, old != requested.lane { compactLaneIfNeeded(old) }
        zOrder.removeAll { $0 == windowId }
        zOrder.append(windowId)
    }

    @discardableResult
    func remove(_ windowId: WindowId) -> TileSpan? {
        guard let span = placements.removeValue(forKey: windowId) else { return nil }
        zOrder.removeAll { $0 == windowId }
        compactLaneIfNeeded(span.lane)
        return span
    }

    func promote(_ windowId: WindowId) {
        guard placements[windowId] != nil else { return }
        zOrder.removeAll { $0 == windowId }
        zOrder.append(windowId)
    }

    /// Switch shape (e.g. monitor rotated, or user changed lane count).
    /// Returns evicted windows (those whose lane no longer fits).
    func reshape(to newShape: LayoutShape) -> [WindowId] {
        if newShape == shape { return [] }
        var evicted: [WindowId] = []
        var rebuilt: [WindowId: TileSpan] = [:]
        for (wid, span) in placements {
            if span.lane < newShape.lanes {
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

    /// Lanes containing at least one window. Sorted ascending.
    var usedLanes: [Int] { Set(placements.values.map(\.lane)).sorted() }

    /// Lanes with no windows.
    var emptyLanes: [Int] {
        let used = Set(usedLanes)
        return (0..<shape.lanes).filter { !used.contains($0) }
    }

    /// Number of slots in a lane = `max(slot1) + 1` over its placements.
    func slotCount(in lane: Int) -> Int {
        var maxSlot = -1
        for span in placements.values where span.lane == lane {
            if span.slot1 > maxSlot { maxSlot = span.slot1 }
        }
        return maxSlot + 1
    }

    func windows(in lane: Int) -> [WindowId] {
        placements
            .filter { $0.value.lane == lane }
            .sorted { $0.value.slot0 < $1.value.slot0 }
            .map(\.key)
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

extension GridLayout {
    /// Resolve a window's screen-space rect. `available` is post-outer-gap
    /// workspace rect; `innerGap` separates adjacent USED lanes and
    /// adjacent slots within a lane.
    ///
    /// Empty lanes collapse: only `usedLanes` are rendered, equal extent
    /// along the lane axis.
    func resolveRect(
        for windowId: WindowId,
        in available: Rect,
        innerGap: CGFloat = 0
    ) -> Rect? {
        guard let span = placements[windowId] else { return nil }
        let used = usedLanes
        guard !used.isEmpty else { return nil }
        guard let visIdx = used.firstIndex(of: span.lane) else { return nil }

        // Lane axis: equal partition of `available` along the lane axis.
        let nLanes = CGFloat(used.count)
        let totalLaneGap = max(0, nLanes - 1) * innerGap

        // Slot axis: weighted partition of the lane.
        let slots = slotCount(in: span.lane)
        guard slots > 0, span.slot0 < slots, span.slot1 < slots else { return nil }
        var weights: [CGFloat] = []
        for s in 0..<slots { weights.append(slotWeight(lane: span.lane, slot: s)) }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return nil }
        let totalSlotGap = max(0, CGFloat(slots - 1)) * innerGap

        switch shape.orientation {
            case .landscape:
                // Lane axis = X, slot axis = Y.
                let laneW = (available.width - totalLaneGap) / nLanes
                let usableH = available.height - totalSlotGap
                let x = available.topLeftX + CGFloat(visIdx) * (laneW + innerGap)
                var y0 = available.topLeftY
                for s in 0..<span.slot0 { y0 += weights[s] / totalWeight * usableH + innerGap }
                var spanW: CGFloat = 0
                for s in span.slot0...span.slot1 { spanW += weights[s] }
                let h = spanW / totalWeight * usableH + max(0, CGFloat(span.slot1 - span.slot0)) * innerGap
                return Rect(topLeftX: x, topLeftY: y0, width: laneW, height: h)
            case .portrait:
                // Lane axis = Y, slot axis = X.
                let laneH = (available.height - totalLaneGap) / nLanes
                let usableW = available.width - totalSlotGap
                let y = available.topLeftY + CGFloat(visIdx) * (laneH + innerGap)
                var x0 = available.topLeftX
                for s in 0..<span.slot0 { x0 += weights[s] / totalWeight * usableW + innerGap }
                var spanW: CGFloat = 0
                for s in span.slot0...span.slot1 { spanW += weights[s] }
                let w = spanW / totalWeight * usableW + max(0, CGFloat(span.slot1 - span.slot0)) * innerGap
                return Rect(topLeftX: x0, topLeftY: y, width: w, height: laneH)
        }
    }
}

// MARK: - Placement heuristic

extension GridLayout {
    /// Decide where a new window goes. See docs/MUR_DESIGN.md.
    /// `focusedLane` is the lane of the currently focused tiled window.
    func placementForNewWindow(focusedLane: Int? = nil) -> TileSpan {
        let used = usedLanes

        // Empty workspace → middle lane, sole slot.
        if used.isEmpty { return .soleSlot(lane: shape.middleLane) }

        // Single lane in use: prefer adjacent empty lane.
        if used.count == 1 {
            let lStar = used[0]
            let leftEmpty = lStar - 1 >= 0 && !used.contains(lStar - 1)
            let rightEmpty = lStar + 1 < shape.lanes && !used.contains(lStar + 1)
            switch (leftEmpty, rightEmpty) {
                case (true, true):
                    let leftSpace = lStar
                    let rightSpace = shape.lanes - 1 - lStar
                    return .soleSlot(lane: rightSpace >= leftSpace ? lStar + 1 : lStar - 1)
                case (true, false): return .soleSlot(lane: lStar - 1)
                case (false, true): return .soleSlot(lane: lStar + 1)
                case (false, false): break
            }
        }

        // Multi-lane and empty lane exists → nearest to focus.
        let empties = emptyLanes
        if !empties.isEmpty {
            let anchor = focusedLane ?? shape.middleLane
            let nearest = empties.min { abs($0 - anchor) < abs($1 - anchor) } ?? empties[0]
            return .soleSlot(lane: nearest)
        }

        // No empty lane: ADD a new slot at the bottom of the focused lane
        // (or middle if no focus). Per-lane flexible slots make this
        // preferable to overlapping.
        let targetLane = focusedLane ?? shape.middleLane
        let newSlot = slotCount(in: targetLane)
        return .single(lane: targetLane, slot: newSlot)
    }
}
