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
