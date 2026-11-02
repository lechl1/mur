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
    /// Workspace the window was dragged from.
    let workspace: Workspace
    /// Workspace under the cursor: the active one of the monitor the mouse
    /// is on. Differs from `workspace` when the drag crosses monitors.
    var targetWorkspace: Workspace
    /// Cell of `targetWorkspace`'s grid under the cursor. nil → that grid
    /// is empty.
    var hoverCell: (lane: Int, slot: Int)?
}

/// Drop the dragged window: into the hovered cell, and — when the drag
/// ended on another monitor — onto that monitor's workspace first. Without
/// the move a window dropped on the other monitor was hit-tested against
/// its own grid, landed in its own last column and snapped back.
@MainActor
func commitStackingDrop(_ session: StackingDragSession) {
    guard let window = Window.get(byId: session.windowId) else { return }
    let target = session.targetWorkspace
    if target != session.workspace {
        _ = session.workspace.stackingLayout.remove(window.windowId)
        _ = moveWindowToWorkspace(
            window, target, CmdIo(stdin: .emptyStdin),
            focusFollowsWindow: true, failIfNoop: false,
            // An empty destination grid has no cell to hover: let the
            // placement heuristic mount it.
            mountInGrid: session.hoverCell == nil,
        )
    }
    // A window the user floated stays floating where it was dropped: in the
    // grid ⇒ tiled in the tree.
    if let cell = session.hoverCell, !window.isFloating {
        target.stackingLayout.place(window.windowId, at: .single(lane: cell.lane, slot: cell.slot))
    }
}
