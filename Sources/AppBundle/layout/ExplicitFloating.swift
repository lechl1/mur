import AppKit
import Common

/// mur — the windows the user floated through mur: `layout floating` (also
/// from an `on-window-detected` callback) and `stacking-float`. These are
/// the ONLY floating windows. mur never floats a window on its own
/// judgement — not a dialog, not an app on a list, not a window that seemed
/// to refuse a resize — and `tileWindowsNotExplicitlyFloating` tiles any
/// other window that ends up floating anyway (the inherited tree code still
/// binds some as floating: a dialog-looking window at registration, one
/// back from minimize or fullscreen, the closed-windows cache).
@MainActor var explicitlyFloatingWindowIds: Set<WindowId> = []

/// Tile every floating window the user didn't float (and that can be seen —
/// see `ghostWindowIds`). Runs in every full
/// refresh, after the windows have been registered and normalized.
@MainActor
func tileWindowsNotExplicitlyFloating() {
    for workspace in Workspace.all {
        for window in workspace.floatingWindows where !explicitlyFloatingWindowIds.contains(window.windowId) && !ghostWindowIds.contains(window.windowId) {
            window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            tryRegisterInStackingLayout(window)
        }
    }
}
