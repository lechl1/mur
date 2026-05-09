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
func tryRegisterInGridLayout(_ window: Window) async throws {
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

    let appId = window.app.rawAppBundleId ?? ""
    // Title fetch can throw or return nil if the AX request races the
    // window's full initialisation. Treat any failure as "no title yet"
    // and use an empty string — that still gives per-app memory.
    let title = (try? await window.title) ?? ""
    let shape = workspace.gridLayout.shape

    let span: TileSpan
    if let recalled = windowMemory.recall(appId: appId, title: title, shape: shape) {
        span = recalled
    } else {
        // Anchor the heuristic to the focused tiled window's lane if any.
        let focusedLane = workspace.gridLayout.placements[
            (try? await getNativeFocusedWindow())?.windowId ?? 0
        ]?.lane
        span = workspace.gridLayout.placementForNewWindow(focusedLane: focusedLane)
        windowMemory.remember(appId: appId, title: title, shape: shape, span: span)
        windowMemory.save()
    }
    workspace.gridLayout.place(window.windowId, at: span)
}
