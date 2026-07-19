import AppKit

@MainActor var currentlyManipulatedWithMouseWindowId: UInt32? = nil

/// Set to the window id once a mouse-driven RESIZE gesture has been
/// detected (an edge is being dragged), cleared on mouse-up in
/// `resetManipulatedWithMouseIfPossible`. Dragging the LEFT or TOP edge
/// fires `kAXMovedNotification` alongside the resize; the move handler
/// consults this flag to avoid hijacking the gesture into a move / grid
/// drag-session (which would null the resize baseline and snap the
/// window back on mouse-up). More reliable than comparing sizes, since
/// the resize handler continuously advances `lastAppliedLayoutPhysicalRect`.
@MainActor var currentlyResizedWithMouseWindowId: UInt32? = nil

var isLeftMouseButtonDown: Bool { NSEvent.pressedMouseButtons == 1 }

@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    try await (!window.isHiddenInCorner && // Don't allow to resize/move windows of hidden workspaces
        isLeftMouseButtonDown &&
        (currentlyManipulatedWithMouseWindowId == nil || window.windowId == currentlyManipulatedWithMouseWindowId))
        .andAsync { @Sendable @MainActor in
            // mur — treat focus-query timeout as "not the focused window".
            // A slow AX should not raise here either.
            do {
                return try await getNativeFocusedWindow() == window
            } catch is FocusedWindowTimeoutError {
                return false
            }
        }
}

/// Same motivation as in monitorFrameNormalized
var mouseLocation: CGPoint {
    let mainMonitorHeight: CGFloat = mainMonitor.height
    let location = NSEvent.mouseLocation
    return location.copy(\.y, mainMonitorHeight - location.y)
}
