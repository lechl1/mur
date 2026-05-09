import AppKit
import Common

// MARK: - GridShape

/// Fixed cell count of a predefined layout. The default mur layout is 3×3.
/// See `docs/MUR_DESIGN.md`.
struct GridShape: Equatable, Hashable {
    let cols: Int
    let rows: Int

    init(cols: Int, rows: Int) {
        precondition(cols >= 1, "GridShape requires cols >= 1, got \(cols)")
        precondition(rows >= 1, "GridShape requires rows >= 1, got \(rows)")
        self.cols = cols
        self.rows = rows
    }

    /// The default mur layout — 3 columns × 3 rows.
    static let defaultLayout = GridShape(cols: 3, rows: 3)

    var middleCol: Int { cols / 2 }
    var middleRow: Int { rows / 2 }
}

// MARK: - TileSpan

/// A contiguous, axis-aligned rectangle of grid cells occupied by one window.
/// Spans MAY overlap other windows' spans — overlap is the stacking primitive.
struct TileSpan: Equatable, Hashable {
    let col0: Int
    let row0: Int
    let col1: Int
    let row1: Int

    init(col0: Int, row0: Int, col1: Int, row1: Int) {
        precondition(col0 <= col1, "TileSpan: col0 (\(col0)) must be <= col1 (\(col1))")
        precondition(row0 <= row1, "TileSpan: row0 (\(row0)) must be <= row1 (\(row1))")
        self.col0 = col0
        self.row0 = row0
        self.col1 = col1
        self.row1 = row1
    }

    /// Single cell at (col, row).
    static func cell(col: Int, row: Int) -> TileSpan {
        TileSpan(col0: col, row0: row, col1: col, row1: row)
    }

    /// Full-row span at `col`, covering all rows of the given shape.
    static func column(_ col: Int, in shape: GridShape) -> TileSpan {
        TileSpan(col0: col, row0: 0, col1: col, row1: shape.rows - 1)
    }

    /// Full-column span at `row`, covering all cols of the given shape.
    static func row(_ row: Int, in shape: GridShape) -> TileSpan {
        TileSpan(col0: 0, row0: row, col1: shape.cols - 1, row1: row)
    }

    /// Every cell of the shape.
    static func full(_ shape: GridShape) -> TileSpan {
        TileSpan(col0: 0, row0: 0, col1: shape.cols - 1, row1: shape.rows - 1)
    }

    var width: Int { col1 - col0 + 1 }
    var height: Int { row1 - row0 + 1 }
    var area: Int { width * height }

    func contains(col: Int, row: Int) -> Bool {
        col0 <= col && col <= col1 && row0 <= row && row <= row1
    }

    func overlaps(_ other: TileSpan) -> Bool {
        !(col1 < other.col0 || other.col1 < col0 || row1 < other.row0 || other.row1 < row0)
    }

    /// Clamp this span to fit inside `shape`. Returns nil if the span has no
    /// overlap with the shape at all (which can happen if a layout change
    /// shrinks the grid below the span's bounds).
    func clamped(to shape: GridShape) -> TileSpan? {
        let c0 = max(0, min(col0, shape.cols - 1))
        let c1 = max(0, min(col1, shape.cols - 1))
        let r0 = max(0, min(row0, shape.rows - 1))
        let r1 = max(0, min(row1, shape.rows - 1))
        if c0 > c1 || r0 > r1 { return nil }
        return TileSpan(col0: c0, row0: r0, col1: c1, row1: r1)
    }
}

// MARK: - GridLayout

typealias WindowId = UInt32

/// Per-workspace grid state. Replaces the AeroSpace tree of `TilingContainer`s.
/// One layout per workspace; nesting is not supported by design.
final class GridLayout {
    private(set) var shape: GridShape

    /// Tiled windows and their spans. Windows not in this map are either
    /// floating (workspace-level list, unchanged from AeroSpace) or unmanaged
    /// (macOS native fullscreen / minimised / popup shims).
    private(set) var placements: [WindowId: TileSpan] = [:]

    /// Stacking order for tiled windows, back → front. The last element
    /// renders on top. Promoted on focus and on placement.
    private(set) var zOrder: [WindowId] = []

    init(shape: GridShape = .defaultLayout) {
        self.shape = shape
    }

    var isEmpty: Bool { placements.isEmpty }

    // MARK: mutation

    /// Insert or update a window's placement. Promotes to top of `zOrder`.
    func place(_ windowId: WindowId, at span: TileSpan) {
        guard let clamped = span.clamped(to: shape) else {
            // Span does not intersect the current shape; treat as remove.
            remove(windowId)
            return
        }
        placements[windowId] = clamped
        zOrder.removeAll { $0 == windowId }
        zOrder.append(windowId)
    }

    /// Remove a window from the grid (because it closed, was floated, or
    /// moved to another workspace). No-op if not present.
    @discardableResult
    func remove(_ windowId: WindowId) -> TileSpan? {
        let removed = placements.removeValue(forKey: windowId)
        if removed != nil {
            zOrder.removeAll { $0 == windowId }
        }
        return removed
    }

    /// Promote a window to the top of `zOrder` without changing its span.
    /// Called on focus.
    func promote(_ windowId: WindowId) {
        guard placements[windowId] != nil else { return }
        zOrder.removeAll { $0 == windowId }
        zOrder.append(windowId)
    }

    /// Switch to a different grid shape. Existing placements are clamped;
    /// any that no longer fit are evicted (caller is responsible for
    /// re-placing them, e.g. via the heuristic).
    /// Returns the windows that were evicted.
    func reshape(to newShape: GridShape) -> [WindowId] {
        if newShape == shape { return [] }
        var evicted: [WindowId] = []
        var rebuilt: [WindowId: TileSpan] = [:]
        for (wid, span) in placements {
            if let clamped = span.clamped(to: newShape) {
                rebuilt[wid] = clamped
            } else {
                evicted.append(wid)
            }
        }
        shape = newShape
        placements = rebuilt
        zOrder.removeAll { evicted.contains($0) }
        return evicted
    }

    // MARK: queries

    /// Used columns: the set of column indices touched by at least one window.
    /// Sorted ascending.
    var usedCols: [Int] {
        var seen: Set<Int> = []
        for span in placements.values {
            for c in span.col0...span.col1 { seen.insert(c) }
        }
        return seen.sorted()
    }

    /// Used rows: the set of row indices touched by at least one window.
    /// Sorted ascending.
    var usedRows: [Int] {
        var seen: Set<Int> = []
        for span in placements.values {
            for r in span.row0...span.row1 { seen.insert(r) }
        }
        return seen.sorted()
    }

    /// Columns that are completely empty (no window touches them).
    var emptyCols: [Int] {
        let used = Set(usedCols)
        return (0..<shape.cols).filter { !used.contains($0) }
    }

    var emptyRows: [Int] {
        let used = Set(usedRows)
        return (0..<shape.rows).filter { !used.contains($0) }
    }
}

// MARK: - Geometry: track collapsing

extension GridLayout {
    /// Resolve a placement to a screen-space rectangle inside `available`.
    ///
    /// Empty rows/columns collapse — only `usedCols` × `usedRows` cells are
    /// rendered, sized equally inside `available`. `innerGap` separates
    /// adjacent USED cells (not absolute cells); outer gaps must already be
    /// applied to `available` by the caller.
    func resolveRect(
        for windowId: WindowId,
        in available: Rect,
        innerGap: CGFloat = 0
    ) -> Rect? {
        guard let span = placements[windowId] else { return nil }

        let usedColsList = usedCols
        let usedRowsList = usedRows
        guard !usedColsList.isEmpty, !usedRowsList.isEmpty else { return nil }

        // Map absolute (col, row) → used index.
        // Span covers absolute cols [col0..col1]; intersect with usedCols.
        let spanUsedCols = usedColsList.enumerated()
            .filter { (_, absCol) in span.col0 <= absCol && absCol <= span.col1 }
            .map { $0.offset }
        let spanUsedRows = usedRowsList.enumerated()
            .filter { (_, absRow) in span.row0 <= absRow && absRow <= span.row1 }
            .map { $0.offset }

        guard let cFirst = spanUsedCols.first, let cLast = spanUsedCols.last,
              let rFirst = spanUsedRows.first, let rLast = spanUsedRows.last
        else { return nil }

        let nCols = CGFloat(usedColsList.count)
        let nRows = CGFloat(usedRowsList.count)

        // Total gap budget: (n-1) gaps between n cells.
        let totalColGap = max(0, nCols - 1) * innerGap
        let totalRowGap = max(0, nRows - 1) * innerGap
        let cellW = (available.width - totalColGap) / nCols
        let cellH = (available.height - totalRowGap) / nRows

        let x0 = available.topLeftX + CGFloat(cFirst) * (cellW + innerGap)
        let y0 = available.topLeftY + CGFloat(rFirst) * (cellH + innerGap)
        let spanCols = CGFloat(cLast - cFirst + 1)
        let spanRows = CGFloat(rLast - rFirst + 1)
        let w = spanCols * cellW + max(0, spanCols - 1) * innerGap
        let h = spanRows * cellH + max(0, spanRows - 1) * innerGap

        return Rect(topLeftX: x0, topLeftY: y0, width: w, height: h)
    }
}

// MARK: - Placement heuristic

extension GridLayout {
    /// Decide where a brand-new (or restored-without-memory) window should go.
    /// See `docs/MUR_DESIGN.md` § "New-window placement heuristic".
    ///
    /// `focusedWindowCol` is the column of the currently focused tiled
    /// window, if any (used for tie-breaking when multiple empty columns
    /// exist). `nil` means there's no focused tiled window.
    func placementForNewWindow(focusedWindowCol: Int? = nil) -> TileSpan {
        let used = usedCols

        // Case 1: empty workspace — middle column, full rows.
        if used.isEmpty {
            return .column(shape.middleCol, in: shape)
        }

        // Case 2: exactly one column in use.
        if used.count == 1 {
            let cStar = used[0]
            let leftEmpty = cStar - 1 >= 0 && emptyCols.contains(cStar - 1)
            let rightEmpty = cStar + 1 < shape.cols && emptyCols.contains(cStar + 1)
            // Prefer the side with more empty space (further from cStar).
            // Tiebreak: right.
            switch (leftEmpty, rightEmpty) {
                case (true, true):
                    let leftSpace = cStar
                    let rightSpace = shape.cols - 1 - cStar
                    return .column(rightSpace >= leftSpace ? cStar + 1 : cStar - 1, in: shape)
                case (true, false): return .column(cStar - 1, in: shape)
                case (false, true): return .column(cStar + 1, in: shape)
                case (false, false): break // fall through
            }
        }

        // Case 3: any fully-empty column exists — pick nearest to focused.
        let empties = emptyCols
        if !empties.isEmpty {
            let anchor = focusedWindowCol ?? shape.middleCol
            let nearest = empties.min { abs($0 - anchor) < abs($1 - anchor) } ?? empties[0]
            return .column(nearest, in: shape)
        }

        // Case 4: no empty column — overlap the middle column. Stacking ftw.
        return .column(shape.middleCol, in: shape)
    }
}
