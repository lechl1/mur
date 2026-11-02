import AppKit
import Common

/// Notices the mouse crossing onto another monitor. Only a crossing counts:
/// a keyboard focus change onto the other monitor must not be undone by the
/// next jiggle of a mouse resting where it was.
struct MouseMonitorTracker {
    private var lastCorner: CGPoint? = nil

    /// Records the monitor (by its top-left corner) the mouse is on; true
    /// when that's a different monitor than at the previous call.
    mutating func crossed(onto corner: CGPoint) -> Bool {
        defer { lastCorner = corner }
        guard let lastCorner else { return false }
        return lastCorner != corner
    }
}

@MainActor private var mouseMonitorTracker = MouseMonitorTracker()

/// mur — `focus-follows-mouse-across-monitors`: focus the workspace of the
/// monitor the mouse just moved onto, as a click on it already does.
@MainActor
func onGlobalMouseMoved() {
    guard config.focusFollowsMouseAcrossMonitors else { return }
    let monitor = mouseLocation.monitorApproximation
    guard mouseMonitorTracker.crossed(onto: monitor.rect.topLeftCorner) else { return }
    let target = monitor.activeWorkspace
    guard target != focus.workspace else { return }
    fireAndForget { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        _ = try await runLightSession(.globalObserverMouseMoved, token) {
            target.focusWorkspace()
        }
    }
}
