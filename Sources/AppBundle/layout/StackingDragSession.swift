import AppKit
import Common

/// Tracks an in-progress drag-and-drop of a stacking-tiled window. Set by
/// `moveWithMouse` while the user holds the mouse and drags a window;
/// read by the global mouse-up handler to snap the dropped window into
/// the hovered cell.
@MainActor var gridDragSession: StackingDragSession? = nil

@MainActor
struct StackingDragSession {
    let windowId: WindowId
    let workspace: Workspace
    let sourceSpan: TileSpan
    /// Cell currently under the cursor. nil → outside grid bounds.
    var hoverCell: (lane: Int, slot: Int)?
}
