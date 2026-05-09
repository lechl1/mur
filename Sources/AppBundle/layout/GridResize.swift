import AppKit
import Common

/// Mouse-driven resize for tiled windows. Preserves AeroSpace's
/// "drag any edge, the layout follows" feel — including the
/// neighbouring-column resize when the user drags a lane-axis edge.
///
/// Pipeline (matches AeroSpace's `resizeWithMouse`):
///   1. AX fires `kAXResizedNotification` — `resizedObs` enqueues a light
///      session if `isManipulatedWithMouse`.
///   2. Diff `window.getAxRect()` against `lastAppliedLayoutPhysicalRect`
///      to learn which edges moved.
///   3. `GridResize.snap(...)` translates the drag into:
///        - a new slot-weights vector for the affected lane, AND/OR
///        - a new lane-weights vector (lane-axis drag).
///   4. Caller applies via `layout.setSlotWeights(...)` and/or
///      `layout.setLaneWeights(...)` and schedules a refresh.
///
/// Axis mapping by orientation:
///   - `.landscape`: lane axis = X, slot axis = Y. Left/right drags
///     redistribute lane weights (column widths); top/bottom drags
///     redistribute slot weights (row heights within the column).
///   - `.portrait`: lane axis = Y, slot axis = X. Top/bottom drags
///     redistribute lane weights (row heights); left/right drags
///     redistribute slot weights (column widths within the row).
///
/// Floating windows are out of scope — they keep AeroSpace's free-form
/// pixel resize.
enum GridResize {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left   = Edges(rawValue: 1 << 0)
        static let right  = Edges(rawValue: 1 << 1)
        static let top    = Edges(rawValue: 1 << 2)
        static let bottom = Edges(rawValue: 1 << 3)
    }

    struct DragSample {
        let layout: GridLayout
        let windowId: WindowId
        let lastAppliedRect: Rect
        let currentRect: Rect
        let available: Rect
        let innerGap: CGFloat
    }

    /// Result of a successful drag. May carry slot weights, lane weights,
    /// both (if user dragged a corner), or nil-result for no-op drags.
    struct ResizeResult {
        /// New slot-weights vector for `slotLane` (nil if no slot-axis drag).
        let slotLane: Int?
        let slotWeights: [CGFloat]?
        /// New lane-weights vector for the whole layout (nil if no lane-axis drag).
        let laneWeights: [CGFloat]?

        var isEmpty: Bool { slotWeights == nil && laneWeights == nil }
    }

    /// Detect dragged edges, epsilon-tolerant.
    static func detectEdges(_ s: DragSample, epsilon: CGFloat = 1.0) -> Edges {
        var e: Edges = []
        if abs(s.lastAppliedRect.minX - s.currentRect.minX) > epsilon { e.insert(.left) }
        if abs(s.lastAppliedRect.maxX - s.currentRect.maxX) > epsilon { e.insert(.right) }
        if abs(s.lastAppliedRect.minY - s.currentRect.minY) > epsilon { e.insert(.top) }
        if abs(s.lastAppliedRect.maxY - s.currentRect.maxY) > epsilon { e.insert(.bottom) }
        return e
    }

    /// Compute new lane-weights and/or slot-weights from the drag.
    /// Returns nil if nothing changed.
    static func snap(_ sample: DragSample) -> ResizeResult? {
        guard let span = sample.layout.placements[sample.windowId] else { return nil }
        let edges = detectEdges(sample)
        if edges.isEmpty { return nil }

        let orientation = sample.layout.shape.orientation

        // Pull out per-axis touched flags + raw deltas. Convention:
        //   *Low  = "low end" edge → top in landscape Y / left in portrait X.
        //   *High = "high end" edge → bottom or right.
        //   delta > 0 → window grew on that edge (edge moved outward).
        let slotLow: Bool, slotHigh: Bool
        let laneLow: Bool, laneHigh: Bool
        let slotAxisExtent: CGFloat, laneAxisExtent: CGFloat
        let slotLowDelta: CGFloat, slotHighDelta: CGFloat
        let laneLowDelta: CGFloat, laneHighDelta: CGFloat
        switch orientation {
            case .landscape:
                slotLow  = edges.contains(.top)
                slotHigh = edges.contains(.bottom)
                laneLow  = edges.contains(.left)
                laneHigh = edges.contains(.right)
                slotAxisExtent = sample.available.height
                laneAxisExtent = sample.available.width
                slotLowDelta  = sample.lastAppliedRect.minY - sample.currentRect.minY
                slotHighDelta = sample.currentRect.maxY - sample.lastAppliedRect.maxY
                laneLowDelta  = sample.lastAppliedRect.minX - sample.currentRect.minX
                laneHighDelta = sample.currentRect.maxX - sample.lastAppliedRect.maxX
            case .portrait:
                slotLow  = edges.contains(.left)
                slotHigh = edges.contains(.right)
                laneLow  = edges.contains(.top)
                laneHigh = edges.contains(.bottom)
                slotAxisExtent = sample.available.width
                laneAxisExtent = sample.available.height
                slotLowDelta  = sample.lastAppliedRect.minX - sample.currentRect.minX
                slotHighDelta = sample.currentRect.maxX - sample.lastAppliedRect.maxX
                laneLowDelta  = sample.lastAppliedRect.minY - sample.currentRect.minY
                laneHighDelta = sample.currentRect.maxY - sample.lastAppliedRect.maxY
        }

        // -- slot-axis transfer (within current lane) ---------------
        // For multi-lane spans, slot weights are read/written on `lane0`
        // (canonical). resolveRect uses lane0's slot weights too, so the
        // visual feedback stays consistent.
        var resultSlotLane: Int? = nil
        var resultSlotWeights: [CGFloat]? = nil
        if slotLow || slotHigh {
            let lane = span.lane0
            let slots = sample.layout.slotCount(in: lane)
            if slots > 1 {
                var weights: [CGFloat] = []
                for s in 0..<slots { weights.append(sample.layout.slotWeight(lane: lane, slot: s)) }
                let total = weights.reduce(0, +)
                let usable = slotAxisExtent - max(0, CGFloat(slots - 1)) * sample.innerGap
                if total > 0 && usable > 0 {
                    if slotLow, span.slot0 > 0 {
                        let d = (slotLowDelta / usable) * total
                        transfer(&weights, from: span.slot0 - 1, to: span.slot0, delta: d)
                    }
                    if slotHigh, span.slot1 < slots - 1 {
                        let d = (slotHighDelta / usable) * total
                        transfer(&weights, from: span.slot1 + 1, to: span.slot1, delta: d)
                    }
                    resultSlotLane = lane
                    resultSlotWeights = weights
                }
            }
        }

        // -- lane-axis transfer (across used lanes) ------------------
        // AeroSpace-style: dragging the right edge of a window grows
        // its column and shrinks the column to its right (and v.v.).
        // We operate on the USED-LANES partition; transfers happen
        // between the dragged window's outer lane (lane0 for low edges,
        // lane1 for high edges) and the immediate visible-neighbour
        // lane on the dragged side.
        var resultLaneWeights: [CGFloat]? = nil
        if laneLow || laneHigh {
            let used = sample.layout.usedLanes
            let visIdx0 = used.firstIndex(of: span.lane0)
            let visIdx1 = used.firstIndex(of: span.lane1)
            if visIdx0 != nil || visIdx1 != nil {
                var weights: [CGFloat] = []
                for l in 0..<sample.layout.shape.lanes {
                    weights.append(sample.layout.laneWeight(lane: l))
                }
                // Sum across USED lanes only — that's what the visible
                // partition uses, so deltas in pixels translate to
                // deltas in this sum.
                let usedTotal = used.reduce(0.0) { $0 + weights[$1] }
                let usable = laneAxisExtent - max(0, CGFloat(used.count - 1)) * sample.innerGap
                if usedTotal > 0 && usable > 0 {
                    if laneLow, let i0 = visIdx0, i0 > 0 {
                        // Drag low-edge outward → grow current lane (lane0),
                        // shrink the previous USED lane.
                        let d = (laneLowDelta / usable) * usedTotal
                        transfer(&weights, from: used[i0 - 1], to: span.lane0, delta: d)
                    }
                    if laneHigh, let i1 = visIdx1, i1 < used.count - 1 {
                        let d = (laneHighDelta / usable) * usedTotal
                        transfer(&weights, from: used[i1 + 1], to: span.lane1, delta: d)
                    }
                    resultLaneWeights = weights
                }
            }
        }

        let result = ResizeResult(
            slotLane: resultSlotLane,
            slotWeights: resultSlotWeights,
            laneWeights: resultLaneWeights,
        )
        return result.isEmpty ? nil : result
    }

    /// Move `delta` weight from index `from` to index `to`. Floors at
    /// `minWeight` so a slot can't disappear.
    private static func transfer(_ weights: inout [CGFloat], from: Int, to: Int, delta: CGFloat) {
        let minWeight: CGFloat = 0.05
        guard from >= 0, from < weights.count, to >= 0, to < weights.count else { return }
        // Clamp to the available slack on both sides.
        let positiveCap = weights[from] - minWeight     // most we can take from `from`
        let negativeCap = -(weights[to] - minWeight)    // most we can give back (delta < 0)
        let clamped = max(negativeCap, min(positiveCap, delta))
        weights[from] -= clamped
        weights[to]   += clamped
    }
}

/// Floating windows keep AeroSpace's free-form pixel resize (the existing
/// `Window.lastFloatingSize` path is unchanged). This enum exists for
/// documentation/grouping only.
enum FloatingResize {}
