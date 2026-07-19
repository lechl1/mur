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

/// Hardcoded list of bundle IDs that should open FLOATING and CENTERED
/// rather than tiled — the macOS System Settings app and other
/// system dialog / utility windows. Extend as needed. (True modal dialogs
/// with a dialog subrole are already handled via the popup shim; this list
/// catches whole apps that present as normal windows but are dialog-like.)
@MainActor let floatByDefaultBundleIds: Set<String> = [
    "com.apple.systempreferences", // System Settings / System Preferences
    "com.apple.SystemProfiler",    // System Information ("About This Mac")
    "com.apple.ScreenSharing",     // Screen Sharing
    "com.apple.print.add",         // Add Printer
    "com.apple.PrintCenter",       // Print dialogs / queue
    "com.apple.ColorSyncUtility",  // ColorSync Utility
    "com.apple.KeychainAccess",    // Keychain Access
]

/// Pull `window` out of the grid, float it, and centre it on its monitor.
/// The centring reads the window's AX size, so it's done asynchronously
/// off the sync registration hot path.
@MainActor
func floatAndCenterWindow(_ window: Window, in workspace: Workspace) {
    workspace.stackingLayout.remove(window.windowId)
    window.bindAsFloatingWindow(to: workspace)
    let windowId = window.windowId
    Task { @MainActor in
        guard let window = Window.get(byId: windowId), let workspace = window.nodeWorkspace else { return }
        let monRect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let size: CGSize = (try? await window.getAxRect())?.size
            ?? window.lastFloatingSize
            ?? CGSize(width: monRect.width / 2, height: monRect.height / 2)
        let cx = monRect.topLeftX + (monRect.width - size.width) / 2
        let cy = monRect.topLeftY + (monRect.height - size.height) / 2
        window.setAxFrame(CGPoint(x: cx, y: cy), size)
    }
}

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

    // mur — System Settings & other macOS dialog/utility apps float and
    // centre by default (hardcoded list). Skip grid registration. A user
    // who explicitly tiles one still gets it restored tiled via window
    // memory (the async restore overrides this default).
    if !appId.isEmpty && floatByDefaultBundleIds.contains(appId) {
        floatAndCenterWindow(window, in: workspace)
        return
    }
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

    // Place heuristically for now (sync, no title). The PRECISE per-title
    // state — floating vs tiled, and where — is restored asynchronously by
    // `restoreWindowStateOnRegister(_:)`, which can await the window title
    // off this hot path. Anchor the heuristic to the focused tiled window's
    // lane if any (cached `focus`, sync).
    _ = shape
    let focusedLane = focus.windowOrNil
        .flatMap { workspace.stackingLayout.placements[$0.windowId]?.lane0 }
    let span = workspace.stackingLayout.placementForNewWindow(focusedLane: focusedLane)
    workspace.stackingLayout.place(window.windowId, at: span)
}

/// Windows awaiting a coordinated restore, and the debounced task that runs
/// it. Restore is batched (not per-window) so a whole workspace — including
/// multi-row columns — is reconstructed together; see `runCoordinatedRestore`.
@MainActor private var pendingRestoreIds: Set<WindowId> = []
@MainActor private var coordinatedRestoreTask: Task<Void, Never>?

/// Queue `window` for a coordinated restore of its remembered state.
///
/// Restoring windows ONE BY ONE is broken for multi-row columns: `place()`
/// compacts slots after every call, so a window restored to slot 2 of an
/// otherwise-empty column is renumbered to slot 0, and the real slot-0
/// window then collides with it. Instead we collect all just-registered
/// windows (debounced — startup registers them in a tight loop) and rebuild
/// each workspace's grid at once, preserving relative lane/row order.
@MainActor
func restoreWindowStateOnRegister(_ window: Window) {
    guard config.experimentalStackingLayout else { return }
    pendingRestoreIds.insert(window.windowId)
    coordinatedRestoreTask?.cancel()
    coordinatedRestoreTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 90_000_000) // debounce past the registration loop
        if Task.isCancelled { return }
        await runCoordinatedRestore()
    }
}

/// Rebuild the grid for every pending window from `WindowMemory`, preserving
/// each column's relative row order. For each destination workspace the
/// tiled windows are grouped by their stored lane, the distinct lanes are
/// ranked to contiguous columns, and within each lane the windows are sorted
/// by their stored slot and placed at contiguous rows — so multi-row columns
/// come back exactly. Floating windows are re-floated; first-seen windows
/// (no memory) keep their heuristic placement, remembered by real title.
@MainActor
private func runCoordinatedRestore() async {
    let ids = pendingRestoreIds
    pendingRestoreIds = []

    struct Tiled { let window: Window; let workspace: Workspace; let lane: Int; let slot: Int }
    var tiled: [Tiled] = []
    var floaters: [(window: Window, workspace: Workspace)] = []

    for id in ids {
        guard let window = Window.get(byId: id), let curWs = window.nodeWorkspace else { continue }
        let appId = window.app.rawAppBundleId ?? ""
        let title = (try? await window.title) ?? ""
        let shape = curWs.stackingLayout.shape
        guard let state = windowMemory.recall(appId: appId, title: title, shape: shape) else {
            // First-seen — keep the heuristic placement, remember it by title.
            if let span = curWs.stackingLayout.placements[id] {
                windowMemory.remember(appId: appId, title: title, workspace: curWs.name, shape: shape, span: span)
            }
            continue
        }
        let targetWs = (!state.workspace.isEmpty && state.workspace != curWs.name)
            ? Workspace.get(byName: state.workspace) : curWs
        if state.floating {
            floaters.append((window, targetWs))
        } else {
            tiled.append(Tiled(window: window, workspace: targetWs, lane: state.span.lane0, slot: state.span.slot0))
        }
    }

    // Reconstruct each workspace's columns/rows from the tiled windows.
    for (_, group) in Dictionary(grouping: tiled, by: { $0.workspace.name }) {
        guard let workspace = group.first?.workspace else { continue }
        let layout = workspace.stackingLayout
        // Detach every window from wherever it is (incl. other workspaces).
        for t in group {
            t.window.nodeWorkspace?.stackingLayout.remove(t.window.windowId)
            if t.window.nodeWorkspace != workspace {
                t.window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
        }
        // Rank stored lanes → contiguous columns; sort each column by stored
        // slot → contiguous rows.
        let laneRank = Dictionary(uniqueKeysWithValues:
            Set(group.map { $0.lane }).sorted().enumerated().map { ($1, $0) })
        for (lane, laneWindows) in Dictionary(grouping: group, by: { $0.lane }) {
            let column = laneRank[lane] ?? 0
            for (row, t) in laneWindows.sorted(by: { $0.slot < $1.slot }).enumerated() {
                layout.place(t.window.windowId, at: .single(lane: column, slot: row))
            }
        }
    }

    // Re-float the floaters, centred on their monitor.
    for f in floaters {
        f.window.nodeWorkspace?.stackingLayout.remove(f.window.windowId)
        f.window.bindAsFloatingWindow(to: f.workspace)
        let monRect = f.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let size: CGSize = (try? await f.window.getAxRect())?.size
            ?? f.window.lastFloatingSize
            ?? CGSize(width: monRect.width / 2, height: monRect.height / 2)
        let cx = monRect.topLeftX + (monRect.width - size.width) / 2
        let cy = monRect.topLeftY + (monRect.height - size.height) / 2
        f.window.setAxFrame(CGPoint(x: cx, y: cy), size)
    }

    windowMemory.save()
    scheduleCancellableCompleteRefreshSession(.ax("restore-window-state"))
}
