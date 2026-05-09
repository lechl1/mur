import AppKit
import Common

/// Mouse-driven resize for tiled windows. Preserves AeroSpace's
/// "drag any edge, the layout follows" feel.
///
/// Pipeline (matches AeroSpace's `resizeWithMouse`):
///   1. AX fires `kAXResizedNotification` — `resizedObs` enqueues a light
///      session if `isManipulatedWithMouse`.
///   2. Diff `window.getAxRect()` against `lastAppliedLayoutPhysicalRect`
///      to learn which edges moved.
///   3. `GridResize.snap(...)` translates the drag into:
///        - a new slot-weights vector for the affected lane, OR
///        - nothing (drag was along the rigid lane axis — no-op).
///   4. Caller applies via `layout.setSlotWeights(lane:weights:)` and
///      schedules a refresh.
///
/// Axis mapping by orientation:
///   - `.landscape`: lane axis = X (rigid), slot axis = Y. So top/bottom
///     drags adjust slot weights; left/right drags are no-ops.
///   - `.portrait`: lane axis = Y (rigid), slot axis = X. So left/right
///     drags adjust slot weights; top/bottom drags are no-ops.
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

    /// Returned from a successful slot-axis drag. Caller writes via
    /// `layout.setSlotWeights(lane: snap.lane, weights: snap.weights)`.
    struct SlotResize {
        let lane: Int
        let weights: [CGFloat]
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

    /// Compute the new slot-weights vector for the lane the dragged window
    /// is in. Returns nil if no slot-axis drag occurred or the lane has
    /// only 1 slot (nothing to redistribute).
    static func snap(_ sample: DragSample) -> SlotResize? {
        guard let span = sample.layout.placements[sample.windowId] else { return nil }
        let edges = detectEdges(sample)
        if edges.isEmpty { return nil }

        let orientation = sample.layout.shape.orientation
        // Slot-axis edges are the ones that adjust weights:
        //   landscape → top/bottom; portrait → left/right.
        let touchedLow: Bool
        let touchedHigh: Bool
        let axisExtent: CGFloat
        let lowDelta: CGFloat
        let highDelta: CGFloat
        switch orientation {
            case .landscape:
                touchedLow = edges.contains(.top)
                touchedHigh = edges.contains(.bottom)
                axisExtent = sample.available.height
                lowDelta = sample.lastAppliedRect.minY - sample.currentRect.minY  // up = +
                highDelta = sample.currentRect.maxY - sample.lastAppliedRect.maxY // down = +
            case .portrait:
                touchedLow = edges.contains(.left)
                touchedHigh = edges.contains(.right)
                axisExtent = sample.available.width
                lowDelta = sample.lastAppliedRect.minX - sample.currentRect.minX  // left = +
                highDelta = sample.currentRect.maxX - sample.lastAppliedRect.maxX // right = +
        }
        if !touchedLow && !touchedHigh { return nil } // Lane-axis drag → rigid no-op.

        let lane = span.lane
        let slots = sample.layout.slotCount(in: lane)
        guard slots > 1 else { return nil }

        var weights: [CGFloat] = []
        for s in 0..<slots { weights.append(sample.layout.slotWeight(lane: lane, slot: s)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }

        let totalSlotGap = max(0, CGFloat(slots - 1)) * sample.innerGap
        let usable = axisExtent - totalSlotGap
        guard usable > 0 else { return nil }

        if touchedLow, span.slot0 > 0 {
            // Drag low-edge outward (+) → take from prev slot, give to slot0.
            let weightDelta = (lowDelta / usable) * total
            transfer(&weights, from: span.slot0 - 1, to: span.slot0, delta: weightDelta)
        }
        if touchedHigh, span.slot1 < slots - 1 {
            let weightDelta = (highDelta / usable) * total
            transfer(&weights, from: span.slot1 + 1, to: span.slot1, delta: weightDelta)
        }

        return SlotResize(lane: lane, weights: weights)
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
