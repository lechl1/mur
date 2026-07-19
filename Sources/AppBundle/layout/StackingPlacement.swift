import AppKit
import Common

/// Process-wide window memory store. Persists per (app id, window title)
/// the last `TileSpan` mur placed a window in. Re-loaded from
/// `~/.config/mur/window-memory.json` on first access; written on every
/// `remember(...)` via the explicit `save()` call below.
@MainActor let windowMemory = WindowMemory()

/// App bundle IDs whose windows we've previously observed as
/// non-resizable (the auto-float branch in `layoutWorkspaceWithStacking`
/// sets this). New windows of these apps skip grid registration on
/// open and stay floating, so we never see the brief in-grid flash
/// before the float kicks in. In-memory only — apps not seen yet
/// still go through the regular auto-float dance once.
@MainActor var knownNonResizableAppIds: Set<String> = []

/// Hardcoded list of bundle IDs mur recognizes as terminal emulators.
/// A freshly-opened window of one of these apps gets its own column
/// sized to a fixed fraction of the workspace width — see
/// `terminalLaneFraction(for:)` and the terminal branch in
/// `tryRegisterInStackingLayout`.
@MainActor let recognizedTerminalBundleIds: Set<String> = [
    "com.apple.Terminal",        // Terminal.app
    "com.googlecode.iterm2",     // iTerm2
    "com.mitchellh.ghostty",     // Ghostty
    "net.kovidgoyal.kitty",      // kitty
    "org.alacritty",             // Alacritty
    "io.alacritty",              // Alacritty (older builds)
    "com.github.wez.wezterm",    // WezTerm
    "dev.warp.Warp-Stable",      // Warp
    "co.zeit.hyper",             // Hyper
    "com.raphaelamorim.rio",     // Rio
]

/// Fraction of the lane axis a freshly-opened terminal column occupies:
/// 1/5 on ultrawide monitors (aspect ≥ 2:1), 1/3 otherwise. Because the
/// layout is columnar this is the column WIDTH in landscape and the row
/// HEIGHT in portrait (the axes invert with orientation).
@MainActor
func terminalLaneFraction(for monitor: Monitor) -> CGFloat {
    let r = monitor.visibleRectPaddedByOuterGaps
    let aspect = r.height > 0 ? r.width / r.height : 1
    return aspect >= 2.0 ? 1.0 / 5.0 : 1.0 / 3.0
}

/// mur — phase 1.4 entry point.
///
/// Called from `MacWindow.getOrRegister` after the window has been bound
/// into the tree. When the experimental grid is on, register the window
/// in its workspace's `StackingLayout` too:
///
/// 1. Skip non-managed windows (popups, native fullscreen / minimised /
///    hidden — those keep AeroSpace's existing handling).
/// 2. Recall a previous span via `WindowMemory.recall(appId, title)`.
///    Hit → reuse it (clamped to current shape).
/// 3. Miss → run `placementForNewWindow(focusedLane:)` heuristic.
/// 4. `stackingLayout.place(...)` and persist via `WindowMemory.remember`.
///
/// The window remains bound in the tree as well; that's intentional for
/// phase 1 — `layoutWorkspace` dispatches through grid first when
/// `stackingLayout.isEmpty == false`. The tree binding becomes dormant until
/// phase 3 deletes it.
@MainActor
func tryRegisterInStackingLayout(_ window: Window) {
    guard config.experimentalStackingLayout else { return }
    guard let workspace = window.nodeWorkspace else { return }

    // Don't stacking-place macOS-managed special windows. They keep AeroSpace's
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
    // (cached) and `stackingLayout.placements` (in-memory) need.
    //
    // Consequence: WindowMemory is keyed by (appId, "") at registration
    // time — per-app memory, not per-window-title. Title precision is
    // restored when the user explicitly places via `mur stacking-place`,
    // `mur stacking-move`, or `mur stacking-resize`, which run outside the
    // startup hot path and can safely await window.title there.
    let appId = window.app.rawAppBundleId ?? ""
    // Skip grid registration for apps we've previously observed as
    // non-resizable — they'd just be auto-floated milliseconds later
    // anyway. Leaving them as floating from the start avoids the
    // in-grid flash and a wasted setAxFrame round-trip.
    if !appId.isEmpty && knownNonResizableAppIds.contains(appId) { return }
    let shape = workspace.stackingLayout.shape

    // mur — recognized terminals open in their OWN column at a fixed
    // width fraction (1/3, or 1/5 on ultrawide), independent of the
    // generic placement heuristic and window memory. Applied fresh on
    // every open, so window memory is intentionally bypassed here.
    if !appId.isEmpty && recognizedTerminalBundleIds.contains(appId) {
        let layout = workspace.stackingLayout
        let used = layout.usedLanes
        let lane: Int
        if used.isEmpty {
            lane = 0
        } else {
            let next = (used.last ?? -1) + 1
            lane = next < layout.shape.lanes ? next : layout.appendLane()
        }
        layout.place(window.windowId, at: .soleSlot(lane: lane))
        if let placed = layout.placements[window.windowId] {
            // Absolute width so a lone terminal renders centered at 1/3
            // (fit-or-center), matching naru's carousel-disabled feel.
            layout.setLaneAbsoluteWidth(terminalLaneFraction(for: workspace.workspaceMonitor), lane: placed.lane0)
        }
        return
    }

    let span: TileSpan
    if let recalled = windowMemory.recall(appId: appId, title: "", shape: shape) {
        span = recalled
    } else {
        // Anchor the heuristic to the focused tiled window's lane if
        // any. Uses the cached `focus` (sync) instead of
        // getNativeFocusedWindow() (async + AX-bound).
        let focusedLane = focus.windowOrNil
            .flatMap { workspace.stackingLayout.placements[$0.windowId]?.lane0 }
        span = workspace.stackingLayout.placementForNewWindow(focusedLane: focusedLane)
        windowMemory.remember(appId: appId, title: "", shape: shape, span: span)
        windowMemory.save()
    }
    workspace.stackingLayout.place(window.windowId, at: span)
}
