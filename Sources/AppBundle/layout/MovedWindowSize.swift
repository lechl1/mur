import AppKit
import Common

// mur — A MOVED WINDOW KEEPS ITS SIZE (see CLAUDE.md). The grid stores
// fractions, which mean different sizes on different screens and in strips
// of different widths, so these helpers convert through the window's
// rendered rect: what the user saw is what it keeps.

/// Inner gap of `workspace`'s grid (the same one `resolveRect` is given).
@MainActor
func gridInnerGap(_ workspace: Workspace) -> CGFloat {
    CGFloat(ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
        .inner.get(workspace.stackingLayout.shape.orientation == .landscape ? .v : .h))
}

/// Where `window` renders in `workspace`'s grid; nil when it has no cell.
/// Read from the grid, not `lastAppliedLayoutPhysicalRect`, which a mouse
/// drag clears.
@MainActor
func gridRect(of window: Window, in workspace: Workspace) -> Rect? {
    guard workspace.stackingLayout.placements[window.windowId] != nil else { return nil }
    return workspace.stackingLayout.resolveRect(
        for: window.windowId,
        in: workspace.workspaceMonitor.visibleRectPaddedByOuterGaps,
        innerGap: gridInnerGap(workspace),
    ) ?? window.lastAppliedLayoutPhysicalRect
}

/// mur — A WINDOW MOVED TO ANOTHER WORKSPACE GETS A COLUMN OF ITS OWN AT ITS
/// OLD WIDTH, the other columns shrinking in proportion as far as needed
/// (rows instead of columns in portrait). The width is kept in points, so it
/// survives a move to a monitor of another size. `entry` is where it comes
/// in (a drop point, the edge a `stacking-move` crosses): the column goes
/// there; nil appends it. Without `sourceRect` (it had no cell) it opens at
/// the default column width.
@MainActor
func mountInOwnColumn(_ window: Window, in dest: Workspace, keeping sourceRect: Rect?, entry: CGPoint?) {
    let layout = dest.stackingLayout
    let avail = dest.workspaceMonitor.visibleRectPaddedByOuterGaps
    let landscape = layout.shape.orientation == .landscape
    let axis = landscape ? avail.width : avail.height
    let width: CGFloat = if let sourceRect, axis > 0 {
        (landscape ? sourceRect.width : sourceRect.height) / axis
    } else {
        StackingLayout.defaultColumnWidth
    }
    let lane = entry.map { layout.laneInsertionIndex(at: $0, in: avail, innerGap: gridInnerGap(dest)) }
        ?? ((layout.usedLanes.last ?? -1) + 1)
    layout.placeInOwnLane(window.windowId, at: lane, width: width)
}

/// mur — a window extracted into a new column of the same workspace keeps
/// the width it rendered at; the other columns shrink to make room.
@MainActor
func keepColumnWidth(of window: Window, in workspace: Workspace, sourceRect: Rect?) {
    let layout = workspace.stackingLayout
    guard let sourceRect, let span = layout.placements[window.windowId] else { return }
    let avail = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
    let landscape = layout.shape.orientation == .landscape
    let axis = landscape ? avail.width : avail.height
    guard axis > 0 else { return }
    layout.keepLaneWidth((landscape ? sourceRect.width : sourceRect.height) / axis, lane: span.lane0)
}

/// mur — a window moved into another column keeps the height it rendered at
/// (width in portrait), at most an equal share — see `keepSlotShare`.
@MainActor
func keepRowHeight(of window: Window, in workspace: Workspace, sourceRect: Rect?) {
    let layout = workspace.stackingLayout
    guard let sourceRect, let span = layout.placements[window.windowId] else { return }
    let avail = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
    let landscape = layout.shape.orientation == .landscape
    let axis = landscape ? avail.height : avail.width
    guard axis > 0 else { return }
    layout.keepSlotShare((landscape ? sourceRect.height : sourceRect.width) / axis, lane: span.lane0, slot: span.slot0)
}

/// mur — A WINDOW MOVED BACK INTO A COLUMN OF ITS OWN GETS BACK THE SIZE IT
/// HAD WHEN THE USER STARTED MOVING IT (see CLAUDE.md). One window is
/// remembered at a time: the first move of a window records the size it
/// rendered at, its later moves keep that size (joining another column as a
/// row narrows it to that column, and it must not come out at that width),
/// and another window's move replaces it. A resize forgets it: the user has
/// chosen new sizes.
struct MoveSizeMemory {
    private(set) var windowId: WindowId? = nil
    private(set) var size: CGSize? = nil

    /// `windowId` starts a move, rendered at `renderedSize` (nil: no cell).
    /// Returns the size to give it back when it ends up alone in a column.
    mutating func startMove(_ windowId: WindowId, renderedSize: CGSize?) -> CGSize? {
        if windowId != self.windowId || size == nil {
            self.windowId = windowId
            size = renderedSize
        }
        return size
    }

    mutating func forget() {
        windowId = nil
        size = nil
    }
}

@MainActor var moveSizeMemory = MoveSizeMemory()

/// Records the start of a user move of `window`, currently rendered at
/// `rect`, and returns the rect to keep when it lands in a column of its own:
/// `rect` resized to the remembered size, about the same centre (the centre
/// still decides where it enters).
@MainActor
func startMove(of window: Window, renderedAt rect: Rect?) -> Rect? {
    joinedColumnMemory.startMove(window.windowId)
    let size = moveSizeMemory.startMove(window.windowId, renderedSize: rect.map { CGSize(width: $0.width, height: $0.height) })
    guard let rect, let size else { return rect }
    let center = rect.center
    return Rect(
        topLeftX: center.x - size.width / 2,
        topLeftY: center.y - size.height / 2,
        width: size.width,
        height: size.height,
    )
}

/// mur — A WINDOW JOINING ANOTHER COLUMN MEETS IT HALFWAY, FOR NOW (see
/// CLAUDE.md). The column it joins as a row takes the width halfway between
/// its own and the window's (rows in portrait: the height), and the column's
/// old width is remembered. If the same window moves on into another column,
/// another workspace or a column of its own, the column it leaves gets that
/// width back. Otherwise the halfway width is final: another window's move or
/// a resize forgets it. One column is remembered at a time, by the windows
/// it held (indices are rewritten by every compaction).
struct JoinedColumnMemory {
    struct Entry: Equatable {
        /// The window that joined the column.
        let windowId: WindowId
        let workspace: String
        /// The column's windows before it joined.
        let mates: [WindowId]
        /// The column's rendered width then, a fraction of the lane axis.
        let width: CGFloat
    }

    private(set) var entry: Entry? = nil

    mutating func joined(_ entry: Entry) { self.entry = entry }

    /// `windowId` starts a move: another window's move makes the halfway
    /// width final.
    mutating func startMove(_ windowId: WindowId) {
        if entry?.windowId != windowId { entry = nil }
    }

    mutating func forget() { entry = nil }
}

@MainActor var joinedColumnMemory = JoinedColumnMemory()

/// The width halfway between a column's and a window's, both fractions of
/// the lane axis.
func halfwayWidth(column: CGFloat, window: CGFloat) -> CGFloat {
    (column + window) / 2
}

/// The rendered width of the column holding `windowId` in `workspace`, as a
/// fraction of the lane axis (height in portrait). nil without a cell.
@MainActor
func renderedColumnFraction(of windowId: WindowId, in workspace: Workspace) -> CGFloat? {
    let layout = workspace.stackingLayout
    guard let span = layout.placements[windowId] else { return nil }
    let used = layout.usedLanes
    guard let idx = used.firstIndex(of: span.lane0) else { return nil }
    let avail = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
    let axis = layout.shape.orientation == .landscape ? avail.width : avail.height
    guard axis > 0 else { return nil }
    let extents = layout.laneExtents(used: used, laneAxisFull: axis, innerGap: gridInnerGap(workspace)).extents
    return extents[idx] / axis
}

/// A column `window` is about to join: its windows and rendered width,
/// read before the move rewrites the grid.
struct JoinedColumn {
    let mates: [WindowId]
    let width: CGFloat
}

@MainActor
func columnAboutToBeJoined(lane: Int, in workspace: Workspace, by window: Window) -> JoinedColumn? {
    let mates = workspace.stackingLayout.windows(in: lane).filter { $0 != window.windowId }
    guard let first = mates.first, let width = renderedColumnFraction(of: first, in: workspace) else { return nil }
    return JoinedColumn(mates: mates, width: width)
}

/// `window` has joined `column` as a row: the column takes the width halfway
/// between its own and the window's `windowRect` (the size it had when this
/// run of moves began), and its old width is remembered for
/// `restoreColumnLeft`.
@MainActor
func meetHalfway(_ window: Window, joined column: JoinedColumn?, in workspace: Workspace, windowRect: Rect?) {
    let layout = workspace.stackingLayout
    guard let column, let windowRect, let span = layout.placements[window.windowId] else { return }
    let avail = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
    let landscape = layout.shape.orientation == .landscape
    let axis = landscape ? avail.width : avail.height
    guard axis > 0 else { return }
    let own = (landscape ? windowRect.width : windowRect.height) / axis
    layout.keepLaneWidth(halfwayWidth(column: column.width, window: own), lane: span.lane0)
    joinedColumnMemory.joined(.init(
        windowId: window.windowId, workspace: workspace.name, mates: column.mates, width: column.width,
    ))
}

/// After a move of `window`: if it has left the column it joined halfway
/// (another column, another workspace, a column of its own), that column
/// gets its old width back. A move within the column (a row swap) keeps
/// the memory.
@MainActor
func restoreColumnLeft(by window: Window) {
    guard let entry = joinedColumnMemory.entry, entry.windowId == window.windowId else { return }
    let layout = Workspace.get(byName: entry.workspace).stackingLayout
    guard let lane = entry.mates.lazy.compactMap({ layout.placements[$0] }).first?.lane0 else {
        joinedColumnMemory.forget() // the column is gone
        return
    }
    if let mine = layout.placements[window.windowId], mine.lane0 <= lane, lane <= mine.lane1 { return }
    joinedColumnMemory.forget()
    layout.keepLaneWidth(entry.width, lane: lane)
}
