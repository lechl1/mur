import AppKit
import Common

/// Mouse-driven resize for grid-tiled windows. Preserves AeroSpace's
/// "drag any edge, the layout follows" feel while keeping mur's strict
/// rule that windows always occupy a whole-cell `TileSpan`.
///
/// Pipeline (matches AeroSpace's `resizeWithMouse`):
///   1. AX fires `kAXResizedNotification` — `resizeWithMouseTask` enqueues
///      a light session.
///   2. We diff the current AX rect against `lastAppliedLayoutPhysicalRect`
///      to learn which edges the user dragged and by how much.
///   3. `GridResize.snap` converts the dragged edges into a new `TileSpan`
///      by mapping pixel positions onto the visible (collapsed) cell grid.
///   4. Caller commits via `GridLayout.place(windowId, at: newSpan)` and
///      `WindowMemory.remember(...)`. A refresh re-renders.
///
/// Floating windows are intentionally out of scope here — they keep their
/// free-form pixel resize, identical to AeroSpace.
enum GridResize {
    /// Bitmask of which edges the user dragged. Determined by comparing
    /// the AX rect to `lastAppliedLayoutPhysicalRect`. A small `epsilon`
    /// avoids treating sub-pixel jitter as an edge drag.
    struct Edges: OptionSet {
        let rawValue: Int
        static let left   = Edges(rawValue: 1 << 0)
        static let right  = Edges(rawValue: 1 << 1)
        static let top    = Edges(rawValue: 1 << 2)
        static let bottom = Edges(rawValue: 1 << 3)
    }

    /// Inputs the snapper needs from the AX side. Caller fills these in.
    struct DragSample {
        let layout: GridLayout
        /// The window being resized. Must be present in `layout.placements`.
        let windowId: WindowId
        /// The rect mur last laid the window out to (i.e. the snapped grid
        /// rect). Origin and dimensions are screen-space.
        let lastAppliedRect: Rect
        /// The rect AX reports right now after the user drag.
        let currentRect: Rect
        /// The screen-space rect the workspace gets to lay tiles inside,
        /// already padded by outer gaps. (Same `available` passed to
        /// `GridLayout.resolveRect`.)
        let available: Rect
        /// Inner gap between adjacent USED cells. Same value passed to
        /// `resolveRect`. Pass 0 if gaps are off.
        let innerGap: CGFloat
    }

    /// Detect which edges moved beyond `epsilon` pixels.
    static func detectEdges(_ sample: DragSample, epsilon: CGFloat = 1.0) -> Edges {
        var e: Edges = []
        let last = sample.lastAppliedRect
        let cur = sample.currentRect
        // AeroSpace convention: a positive `last.minX - cur.minX` means the
        // user dragged the LEFT edge to the left (window grew leftward).
        if abs(last.minX - cur.minX) > epsilon { e.insert(.left) }
        if abs(last.maxX - cur.maxX) > epsilon { e.insert(.right) }
        if abs(last.minY - cur.minY) > epsilon { e.insert(.top) }
        if abs(last.maxY - cur.maxY) > epsilon { e.insert(.bottom) }
        return e
    }

    /// Snap the dragged window to a new `TileSpan`.
    ///
    /// The mapping is done in *visible-cell* space: empty rows/cols are
    /// already collapsed in `available`, so we resolve each dragged edge
    /// to the nearest visible-cell boundary, then translate that visible
    /// index back to an absolute (col, row) in `layout.shape`.
    ///
    /// Returns `nil` if the window isn't tiled, edges are degenerate, or
    /// the resulting span would be empty.
    static func snap(_ sample: DragSample) -> TileSpan? {
        guard let currentSpan = sample.layout.placements[sample.windowId] else { return nil }
        let edges = detectEdges(sample)
        if edges.isEmpty { return nil }

        let usedColsAbs = sample.layout.usedCols
        let usedRowsAbs = sample.layout.usedRows
        guard !usedColsAbs.isEmpty, !usedRowsAbs.isEmpty else { return nil }

        // Build the visible-cell boundary lines along each axis. With N used
        // cells, we have N+1 boundaries. Boundary i sits at:
        //   available.minX + i * (cellW + innerGap) - innerGap/2  (i>0)
        // We use the cell *centres* of inter-cell gutters as the snap targets.
        let nCols = CGFloat(usedColsAbs.count)
        let nRows = CGFloat(usedRowsAbs.count)
        let totalColGap = max(0, nCols - 1) * sample.innerGap
        let totalRowGap = max(0, nRows - 1) * sample.innerGap
        let cellW = (sample.available.width - totalColGap) / nCols
        let cellH = (sample.available.height - totalRowGap) / nRows

        // Boundary positions (inclusive both ends): i in 0...N maps to the
        // "left edge of visible cell i" (or the right edge of N-1 when i=N).
        func colBoundary(_ i: Int) -> CGFloat {
            // Snap to the LEFT edge of cell i for i in 0..<N, and to the
            // RIGHT edge of cell N-1 for i==N.
            if i <= 0 { return sample.available.minX }
            if i >= usedColsAbs.count {
                return sample.available.minX + nCols * cellW + (nCols - 1) * sample.innerGap
            }
            return sample.available.minX + CGFloat(i) * cellW + CGFloat(i - 1) * sample.innerGap + (sample.innerGap / 2)
        }
        func rowBoundary(_ i: Int) -> CGFloat {
            if i <= 0 { return sample.available.minY }
            if i >= usedRowsAbs.count {
                return sample.available.minY + nRows * cellH + (nRows - 1) * sample.innerGap
            }
            return sample.available.minY + CGFloat(i) * cellH + CGFloat(i - 1) * sample.innerGap + (sample.innerGap / 2)
        }

        // Find the nearest boundary index along an axis to a given pixel.
        // Result range: 0...usedCount (inclusive — N+1 boundaries).
        func nearestColBoundary(_ x: CGFloat) -> Int {
            var best = 0
            var bestDist = CGFloat.infinity
            for i in 0...usedColsAbs.count {
                let d = abs(colBoundary(i) - x)
                if d < bestDist { bestDist = d; best = i }
            }
            return best
        }
        func nearestRowBoundary(_ y: CGFloat) -> Int {
            var best = 0
            var bestDist = CGFloat.infinity
            for i in 0...usedRowsAbs.count {
                let d = abs(rowBoundary(i) - y)
                if d < bestDist { bestDist = d; best = i }
            }
            return best
        }

        // Translate visible-cell index → absolute col/row in shape.
        // - For "start" edges (left/top): visible index `i` (0..<N) maps to
        //   the absolute column `usedColsAbs[i]`. Visible index N is past
        //   the end → absolute `shape.cols - 1` clamped.
        // - For "end" edges (right/bottom): visible index `i` (1...N) maps
        //   to the absolute column `usedColsAbs[i-1]` (the i-th boundary
        //   sits at the right edge of visible cell i-1).
        let cur = sample.currentRect
        var newCol0 = currentSpan.col0
        var newCol1 = currentSpan.col1
        var newRow0 = currentSpan.row0
        var newRow1 = currentSpan.row1

        if edges.contains(.left) {
            let bIdx = nearestColBoundary(cur.minX)
            newCol0 = bIdx < usedColsAbs.count ? usedColsAbs[bIdx] : usedColsAbs.last!
        }
        if edges.contains(.right) {
            let bIdx = nearestColBoundary(cur.maxX)
            // boundary i is the right edge of visible cell i-1
            let visIdx = max(1, bIdx) - 1
            newCol1 = usedColsAbs[min(visIdx, usedColsAbs.count - 1)]
        }
        if edges.contains(.top) {
            let bIdx = nearestRowBoundary(cur.minY)
            newRow0 = bIdx < usedRowsAbs.count ? usedRowsAbs[bIdx] : usedRowsAbs.last!
        }
        if edges.contains(.bottom) {
            let bIdx = nearestRowBoundary(cur.maxY)
            let visIdx = max(1, bIdx) - 1
            newRow1 = usedRowsAbs[min(visIdx, usedRowsAbs.count - 1)]
        }

        // Repair inversions that can happen if the user drags one edge past
        // its opposite.
        if newCol0 > newCol1 { swap(&newCol0, &newCol1) }
        if newRow0 > newRow1 { swap(&newRow0, &newRow1) }

        let snapped = TileSpan(col0: newCol0, row0: newRow0, col1: newCol1, row1: newRow1)
        return snapped.clamped(to: sample.layout.shape)
    }
}

// MARK: - Floating windows

/// Floating windows keep AeroSpace's free-form mouse resize. We just record
/// the new size for layout-on-restore, identical to `lastFloatingSize` in
/// AeroSpace's `Window` model. No grid math involved — this is a marker
/// type for documentation; the existing AX-driven path on `Window` already
/// stores `lastFloatingSize` and is unchanged.
enum FloatingResize {}
