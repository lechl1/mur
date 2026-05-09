import AppKit
import Common

/// Tracks an in-progress drag-and-drop of a grid-tiled window. Set by
/// `moveWithMouse` while the user holds the mouse and drags a window;
/// read by the global mouse-up handler to snap the dropped window into
/// the hovered cell.
@MainActor var gridDragSession: GridDragSession? = nil

@MainActor
struct GridDragSession {
    let windowId: WindowId
    let workspace: Workspace
    let sourceSpan: TileSpan
    /// Cell currently under the cursor. nil → outside grid bounds.
    var hoverCell: (lane: Int, slot: Int)?
}
