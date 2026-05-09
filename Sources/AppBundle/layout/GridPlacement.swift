import AppKit
import Common

/// Process-wide window memory store. Persists per (app id, window title)
/// the last `TileSpan` mur placed a window in. Re-loaded from
/// `~/.config/mur/window-memory.json` on first access; written on every
/// `remember(...)` via the explicit `save()` call below.
@MainActor let windowMemory = WindowMemory()

/// mur — phase 1.4 entry point.
///
/// Called from `MacWindow.getOrRegister` after the window has been bound
/// into the tree. When the experimental grid is on, register the window
/// in its workspace's `GridLayout` too:
///
/// 1. Skip non-managed windows (popups, native fullscreen / minimised /
///    hidden — those keep AeroSpace's existing handling).
/// 2. Recall a previous span via `WindowMemory.recall(appId, title)`.
///    Hit → reuse it (clamped to current shape).
/// 3. Miss → run `placementForNewWindow(focusedLane:)` heuristic.
/// 4. `gridLayout.place(...)` and persist via `WindowMemory.remember`.
///
/// The window remains bound in the tree as well; that's intentional for
/// phase 1 — `layoutWorkspace` dispatches through grid first when
/// `gridLayout.isEmpty == false`. The tree binding becomes dormant until
/// phase 3 deletes it.
@MainActor
func tryRegisterInGridLayout(_ window: Window) {
    guard config.experimentalGridLayout else { return }
    guard let workspace = window.nodeWorkspace else { return }

    // Don't grid-place macOS-managed special windows. They keep AeroSpace's
    // existing handling via the shim containers.
    switch window.parent?.cases {
        case .macosPopupWindowsContainer,
             .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer,
             .macosHiddenAppsWindowsContainer:
            return
        case .none:
            return
        default:
            break
    }

    // IMPORTANT: this runs from MacWindow.getOrRegister during startup
    // heavy refresh, when EVERY existing window is processed. Any AX
    // call we make here can block the entire daemon if a single app's
    // AX is unresponsive. So this function is strictly sync — no
    // `await`, no AX reads beyond what `window.app.rawAppBundleId`
    // (cached) and `gridLayout.placements` (in-memory) need.
    //
    // Consequence: WindowMemory is keyed by (appId, "") at registration
    // time — per-app memory, not per-window-title. Title precision is
    // restored when the user explicitly places via `mur grid-place` /
    // `mur grid-move`, which run outside the startup hot path and
    // can safely await window.title there.
    let appId = window.app.rawAppBundleId ?? ""
    let shape = workspace.gridLayout.shape

    let span: TileSpan
    if let recalled = windowMemory.recall(appId: appId, title: "", shape: shape) {
        span = recalled
    } else {
        // Anchor the heuristic to the focused tiled window's lane if
        // any. Uses the cached `focus` (sync) instead of
        // getNativeFocusedWindow() (async + AX-bound).
        let focusedLane = focus.windowOrNil
            .flatMap { workspace.gridLayout.placements[$0.windowId]?.lane }
        span = workspace.gridLayout.placementForNewWindow(focusedLane: focusedLane)
        windowMemory.remember(appId: appId, title: "", shape: shape, span: span)
        windowMemory.save()
    }
    workspace.gridLayout.place(window.windowId, at: span)
}
