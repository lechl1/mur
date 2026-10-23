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

    // mur — A WINDOW NEVER STARTS FLOATING. It is mounted into the grid
    // right here, synchronously, at the heuristic cell — never parked as a
    // floating window to be mounted "a beat later". That deferral left
    // windows floating whenever the later mount didn't come (a window back
    // from minimize / fullscreen re-registers here with no restore queued),
    // and was only there to avoid a second hop when the async restore found
    // a remembered cell. That hop is avoided at the source instead: outside
    // restore mode a window opened while mur is running keeps this cell
    // (see `openedLaterIds` in `runCoordinatedRestore`).
    mountInStackingLayout(window, in: workspace)
    tileInTreeIfInGrid(window, in: workspace)
}

/// mur — a window the grid placed must be TILED in the tree too. The
/// inherited dialog heuristic binds a window as floating when it registers
/// at a moment it looks like a dialog (Spotify reports a dialog subrole
/// while its app is hidden or still launching); the grid then mounted it
/// anyway. It rendered tiled, but everything that asks `isFloating` — mouse
/// drag, `resize`, `list-windows` — treated it as a floating window.
@MainActor
func tileInTreeIfInGrid(_ window: Window, in workspace: Workspace) {
    guard window.isFloating, workspace.stackingLayout.placements[window.windowId] != nil else { return }
    window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
}

/// mur — windows registered while mur was already running (not part of the
/// startup batch), waiting for the coordinated restore to look at them.
@MainActor private var openedLaterIds: Set<WindowId> = []

/// Forget a window that died before the restore ran.
@MainActor
func forgetOpenedLater(_ windowId: WindowId) {
    openedLaterIds.remove(windowId)
}

/// Drop a window's parked cell on every workspace: it died, or it came back
/// (possibly on another workspace, where the old anchors mean nothing).
@MainActor
func forgetParkedCell(_ windowId: WindowId) {
    for workspace in Workspace.all { workspace.stackingLayout.forgetParked(windowId) }
}

/// Make a window that was just moved to `workspace` visible there. A tiled
/// window gets a cell in the grid; if the placement declines it (an app known
/// to be non-resizable, a dialog-like app) it is floated and centred instead,
/// since a tiled window with no cell is never given a rect and stays where it
/// was. A floating window keeps its old screen coordinates, which on another
/// monitor are somewhere else entirely, so it is pulled onto this monitor.
/// No-op while the grid is off.
@MainActor
func mountMovedWindowInGrid(_ window: Window, in workspace: Workspace) {
    guard config.experimentalStackingLayout else { return }
    if window.isFloating {
        recenterIfOffMonitor(window, in: workspace)
        return
    }
    mountInStackingLayout(window, in: workspace)
    if workspace.stackingLayout.placements[window.windowId] == nil {
        floatAndCenterWindow(window, in: workspace)
    }
}

@MainActor
private func recenterIfOffMonitor(_ window: Window, in workspace: Workspace) {
    let windowId = window.windowId
    Task { @MainActor in
        guard let window = Window.get(byId: windowId), let workspace = window.nodeWorkspace,
              let rect = try? await window.getAxRect() else { return }
        let mon = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let c = rect.center
        if c.x >= mon.topLeftX, c.x <= mon.topLeftX + mon.width,
           c.y >= mon.topLeftY, c.y <= mon.topLeftY + mon.height { return }
        window.setAxFrame(
            CGPoint(x: mon.topLeftX + (mon.width - rect.width) / 2, y: mon.topLeftY + (mon.height - rect.height) / 2),
            rect.size,
        )
    }
}

/// The placement decision itself — see `tryRegisterInStackingLayout`.
@MainActor
private func mountInStackingLayout(_ window: Window, in workspace: Workspace) {
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

    // mur — a window back from ⌘H / minimize / fullscreen goes back where it
    // was, not where a new window would go.
    let unparked = workspace.stackingLayout.unpark(window.windowId)
    forgetParkedCell(window.windowId)
    if unparked { return }

    // mur — recognized terminals open in their OWN column at a fixed
    // width fraction (1/3, or 1/5 on ultrawide), independent of the
    // generic placement heuristic and window memory. Applied fresh on
    // every open, so window memory is intentionally bypassed here.
    if !appId.isEmpty && recognizedTerminalBundleIds.contains(appId) {
        let layout = workspace.stackingLayout
        let used = layout.usedLanes
        let existingWidths = used.map { layout.laneWeight(lane: $0) }
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
            // (fit-or-center), matching naru's carousel-disabled feel — or
            // an equal share when the columns already there fill the screen.
            layout.setLaneAbsoluteWidth(
                StackingLayout.widthForNewColumn(
                    natural: terminalLaneFraction(for: workspace.workspaceMonitor),
                    existing: existingWidths,
                ),
                lane: placed.lane0,
            )
        }
        return
    }

    // mur — a window of an app that had a window here before (the app
    // restarted) goes back to that window's spot in the saved arrangement,
    // beside the same neighbours — not under whichever column has focus.
    if let cell = arrangementStore.takeGhostCell(
        appId: appId, workspace: workspace.name, windowId: window.windowId,
        isPlaced: { workspace.stackingLayout.placements[$0] != nil },
    ), workspace.stackingLayout.placeBeside(window.windowId, cell) {
        return
    }

    // Place heuristically for now (sync, no title). The PRECISE per-title
    // cell is restored asynchronously by
    // `restoreWindowStateOnRegister(_:)`, which can await the window title
    // off this hot path. Anchor the heuristic to the focused tiled window's
    // lane if any (cached `focus`, sync).
    _ = shape
    let focusedLane = focus.windowOrNil
        .flatMap { workspace.stackingLayout.placements[$0.windowId]?.lane0 }
    let layout = workspace.stackingLayout
    let usedBefore = layout.usedLanes
    let existingWidths = usedBefore.map { layout.laneWeight(lane: $0) }
    let span = layout.placementForNewWindow(focusedLane: focusedLane)
    layout.place(window.windowId, at: span)
    // A new column (not a new row) beside columns that fill the screen
    // takes an equal share instead of squeezing in at its stale width.
    if layout.usedLanes.count > usedBefore.count, let placed = layout.placements[window.windowId] {
        layout.setLaneAbsoluteWidth(
            StackingLayout.widthForNewColumn(natural: layout.laneWeight(lane: placed.lane0), existing: existingWidths),
            lane: placed.lane0,
        )
    }
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
    if !isStartup { openedLaterIds.insert(window.windowId) }
    coordinatedRestoreTask?.cancel()
    coordinatedRestoreTask = Task { @MainActor in
        // The 90ms debounce exists for the startup registration loop. Once
        // the first restore has run, a lone new window only needs a beat.
        let debounce: UInt64 = restoreModeDeadline == nil ? 90_000_000 : 15_000_000
        try? await Task.sleep(nanoseconds: debounce)
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

    // mur — RESTORE IS A WINDOW OF TIME, NOT ONE BATCH (naru's
    // `RESTORE_SETTLE`). The first coordinated restore is the startup batch —
    // every pre-existing window registered in one loop, debounced into a
    // single run — but the windows mur is *waiting* for map much later: the
    // terminals mur itself relaunches take seconds to appear, and a browser
    // reopening its tabs can be slower still. Treating only the first batch
    // as "startup" strands every one of those on whatever workspace happened
    // to be active. So restore mode stays on for `restoreSettle` after the
    // first batch, and ends early once every remembered window has been
    // claimed (nothing left to steer).
    if restoreModeDeadline == nil {
        restoreModeDeadline = Date.now.addingTimeInterval(restoreSettle)
        unclaimedRestoreEntries = arrangementStore.entryCount > 0
            ? arrangementStore.entryCount : windowMemory.tiledEntryCount()
    }
    let isStartupRestore = unclaimedRestoreEntries > 0
        && Date.now < (restoreModeDeadline ?? .distantPast)

    struct Tiled { let window: Window; let workspace: Workspace; let lane: Int; let slot: Int }
    // Remembered cells still up for grabs, per app — see the fallback below.
    var appSpanPool: [String: [StoredWindowState]] = [:]
    var tiled: [Tiled] = []
    // Synthetic lanes for windows sent to their app's workspace without a
    // remembered cell: high enough to rank after every real lane.
    let unrankedLaneBase = Int.max - 1000
    var unrankedCount = 0

    for id in ids {
        guard let window = Window.get(byId: id), let curWs = window.nodeWorkspace else {
            forgetOpenedLater(id)
            continue
        }
        let openedLater = openedLaterIds.remove(id) != nil
        let appId = window.app.rawAppBundleId ?? ""
        let title = (try? await window.title) ?? ""
        let shape = curWs.stackingLayout.shape
        // mur — a window the user opened while mur is running was mounted
        // into the grid the moment it registered. Outside restore mode it
        // stays in that cell: re-placing it from memory now would move it a
        // second time — the "new window jumps across the screen". Just
        // remember where it is, by its real title.
        if openedLater, !isStartupRestore {
            if let span = curWs.stackingLayout.placements[id] {
                windowMemory.remember(appId: appId, title: title, workspace: curWs.name, shape: shape, span: span)
            }
            continue
        }
        // mur — A TERMINAL'S TITLE IS NOT AN IDENTITY. Ghostty (with shell
        // integration, and claude on top of it) rewrites the title as work
        // progresses — "◐ Empty columns cleanup" one minute, something else
        // the next — so title-keyed memory misses on almost every restart
        // and the window lands wherever the heuristic puts it: the "windows
        // keep changing position after restore" symptom. The cwd is stable
        // across restarts, so for terminals prefer the remembered session's
        // span. Each terminal in a cwd claims its OWN saved session (title
        // match first, then screen order — `claimTerminalSession`): handing
        // two terminals in one repo the same cell stacked them as rows of
        // one column on every restart, moving them around.
        // The saved arrangement (relative positions) comes first: its column
        // and row are ranks, which is exactly what the rebuild below wants.
        // The absolute-index memories are only the fallback for a window it
        // has never seen.
        var recalled: StoredWindowState?
        // Whether `recalled` names THIS window (title / terminal session)
        // or just a cell its app used to have (the pool below).
        var isAppPoolGuess = false
        if let spot = arrangementStore.claim(await arrangedWindow(window)) {
            recalled = StoredWindowState(
                floating: false,
                span: .single(lane: spot.path.column, slot: spot.path.row),
                workspace: spot.workspace,
            )
            isAppPoolGuess = spot.isAppGuess
        }
        if recalled == nil, sessionRestoreTerminalBundleIds.contains(appId),
           // `resolveTerminalCwd`, not `window.cwd`: a session mur itself
           // relaunched runs `claude` directly, so no shell integration runs
           // and Ghostty NEVER publishes AXDocument for it. Asking the window
           // alone leaves mur's own restored terminals unidentifiable — they
           // miss their session, fall through to the heuristic, and land in
           // whatever workspace happens to be active. Resolving through the
           // spawn record hands them back their remembered workspace + cell.
           let cwd = await resolveTerminalCwd(window),
           let session = claimTerminalSession(cwd: cwd, title: title)
        {
            recalled = StoredWindowState(floating: false, span: session.span, workspace: session.workspace)
        }
        if recalled == nil { recalled = windowMemory.recall(appId: appId, title: title, shape: shape) }
        // Title miss and no terminal session: fall back to this app's
        // remembered cells, handed out in order so N windows of one app
        // keep their relative columns instead of scattering.
        if recalled == nil {
            let pool = appSpanPool[appId] ?? windowMemory.recallTiledByApp(appId: appId, shape: shape)
            if let next = pool.first {
                appSpanPool[appId] = Array(pool.dropFirst())
                recalled = next
                isAppPoolGuess = true
            } else {
                appSpanPool[appId] = []
            }
        }
        guard let state = recalled else {
            // mur — UNRECOGNISED, BUT NOT NECESSARILY NEW. On the startup
            // batch every window was just registered into whichever
            // workspace happened to be active (macOS has no workspaces to
            // read back), so leaving an unrecognised window where it sits
            // strands it there — that's the "windows jump back to the first
            // workspace" symptom, and it hits exactly the windows mur can't
            // key: an app that rewrote its title with no remembered cell
            // left to hand out. Send it to the workspace its app lives in
            // instead; `lane: .max` ranks it after the recognised windows,
            // into the first free column there.
            //
            // Startup only. A window opened later really is new, and the
            // user opened it on the workspace they're looking at.
            if isStartupRestore, !openedLater,
               let home = windowMemory.dominantWorkspace(appId: appId, shape: shape),
               home != curWs.name
            {
                // Distinct synthetic lanes so two unrecognised windows get a
                // column each instead of becoming two rows of one column.
                tiled.append(Tiled(
                    window: window,
                    workspace: Workspace.get(byName: home),
                    lane: unrankedLaneBase + min(unrankedCount, 999),
                    slot: 0,
                ))
                unrankedCount += 1
                continue
            }
            // First-seen — keep the heuristic placement, remember it by title.
            if let span = curWs.stackingLayout.placements[id] {
                windowMemory.remember(appId: appId, title: title, workspace: curWs.name, shape: shape, span: span)
            }
            continue
        }
        // Claimed one of the remembered windows — restore mode ends as soon
        // as there are none left to steer, without waiting out `restoreSettle`.
        unclaimedRestoreEntries -= 1
        // mur — A NEW WINDOW JOINS THE WORKSPACE IT OPENED ON. Only restore
        // steers a window to its remembered workspace (macOS can't tell mur
        // where it was). After that, a window the user opens is new: moving
        // it to wherever its app or title was last seen made it vanish from
        // the workspace on screen the moment it appeared. Even in restore
        // mode, a window that opened after the startup batch is only steered
        // on a match that names it (title / terminal session) — those are
        // what mur is waiting for — never on a guess from its app's pool.
        let steer = isStartupRestore && !(openedLater && isAppPoolGuess)
        let targetWs = (steer && !state.workspace.isEmpty && state.workspace != curWs.name)
            ? Workspace.get(byName: state.workspace) : curWs
        tiled.append(Tiled(window: window, workspace: targetWs, lane: state.span.lane0, slot: state.span.slot0))
    }

    // Reconstruct each workspace's columns/rows from the tiled windows.
    for (_, group) in Dictionary(grouping: tiled, by: { $0.workspace.name }) {
        guard let workspace = group.first?.workspace else { continue }
        let layout = workspace.stackingLayout
        // mur — snapshot the width of every column that was already here
        // (keyed by a window in it), BEFORE the detach below: detaching a
        // just-mounted window closes its column, which hands its width to
        // these survivors. Outside startup they get exactly these widths
        // back — a window joining must not reset its neighbours.
        let groupIds = Set(group.map { $0.window.windowId })
        var existingWidthById: [WindowId: CGFloat] = [:]
        var existingLaneWidths: [Int: CGFloat] = [:]
        for (id, span) in layout.placements where !groupIds.contains(id) {
            existingWidthById[id] = layout.laneWeight(lane: span.lane0)
            existingLaneWidths[span.lane0] = layout.laneWeight(lane: span.lane0)
        }
        // Detach every window from wherever it is (incl. other workspaces).
        for t in group {
            t.window.nodeWorkspace?.stackingLayout.remove(t.window.windowId)
            // Tiled in the tree as well (see `tileInTreeIfInGrid`).
            if t.window.nodeWorkspace != workspace || t.window.isFloating {
                t.window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
        }
        // Rank stored lanes → contiguous columns; sort each column by stored
        // slot → contiguous rows. CRITICAL: place columns in ASCENDING order.
        // `place()` compacts lanes leftward after every call, so placing a
        // high column while lower ones are still empty would shift it to
        // column 0 and make the next columns collide there (all windows
        // stacking in the first column). Ascending placement keeps every
        // just-placed column adjacent to the previous one, so compaction is a
        // no-op and the ranks are preserved.
        //
        // mur — rank against the CURRENT layout, not just this group. At
        // startup the grid is empty after the detach above, so the free
        // lanes are 0,1,2… and this is the historical behaviour. Later —
        // one window opening into a workspace that already has columns —
        // ranking to 0-based columns would drop the newcomer on top of a
        // window that was already there. Take the first lane that is
        // actually free instead.
        var taken = Set(layout.usedLanes)
        var laneRank: [Int: Int] = [:]
        for lane in Set(group.map { $0.lane }).sorted() {
            var column = (0 ..< layout.shape.lanes).first { !taken.contains($0) }
            if column == nil { column = layout.appendLane() }
            taken.insert(column!)
            laneRank[lane] = column!
        }
        let byLane = Dictionary(grouping: group, by: { $0.lane })
        for lane in byLane.keys.sorted() {
            let column = laneRank[lane] ?? 0
            for (row, t) in byLane[lane]!.sorted(by: { $0.slot < $1.slot }).enumerated() {
                layout.place(t.window.windowId, at: .single(lane: column, slot: row))
            }
        }
        // mur — reset every column to its natural width. `place()` rebalances
        // lane weights as each window arrives, and that drift COMPOUNDS over
        // restarts (each restore re-places everything) until the columns
        // render as slivers — 9% of the screen for a terminal, and counting.
        // Widths aren't persisted, so a restore is exactly the moment to
        // start from the defaults again: a terminal column at its fixed
        // fraction, everything else at the default column width.
        //
        // That reset is for the startup batch only. Later, the group is the
        // window(s) that just opened: columns that were already on screen
        // keep their widths, and only a brand-new column gets a default —
        // an equal share if the others already fill the screen, so a
        // full-width terminal plus a new one ends up 50/50, not 1/3 each.
        for lane in layout.usedLanes {
            let ids = layout.windows(in: lane)
            if !isStartupRestore, let kept = ids.lazy.compactMap({ existingWidthById[$0] }).first {
                layout.setLaneAbsoluteWidth(kept, lane: lane)
                continue
            }
            let hasTerminal = ids.contains {
                recognizedTerminalBundleIds.contains(Window.get(byId: $0)?.app.rawAppBundleId ?? "")
            }
            let natural = hasTerminal ? terminalLaneFraction(for: workspace.workspaceMonitor) : StackingLayout.defaultColumnWidth
            layout.setLaneAbsoluteWidth(
                isStartupRestore
                    ? natural
                    : StackingLayout.widthForNewColumn(natural: natural, existing: Array(existingLaneWidths.values)),
                lane: lane,
            )
        }
    }

    windowMemory.save()

    // Record/refresh each terminal's session (cwd + position + claude) so a
    // future restart can restore — and, once, relaunch any saved session
    // whose window is gone (gated by experimental-session-restore).
    // Persist the whole layout (and every terminal's session) on a short
    // ladder — a window that just opened publishes its cwd late.
    persistWindowStateAfterOpen()
    if !didAttemptSessionRelaunch {
        didAttemptSessionRelaunch = true
        relaunchMissingTerminalSessions()
    }

    // Apply the new grid now. The refresh below is coalesced behind any
    // refresh already in flight (up to an AX deadline), and the window would
    // sit where the app opened it until that finished.
    if !isStartupRestore { try? await layoutWorkspaces() }
    scheduleCancellableCompleteRefreshSession(.ax("restore-window-state"))
}

/// One-shot guard: relaunch missing terminal sessions only on the first
/// (startup) coordinated restore, never on later window-open batches.
@MainActor private var didAttemptSessionRelaunch = false

/// mur — how long after the first coordinated restore a window that maps is
/// still treated as part of the restore rather than as one the user just
/// opened. Ported from naru's `RESTORE_SETTLE`: generous, because the
/// windows mur is waiting for are the slow ones — a terminal mur relaunched
/// with `claude --resume`, a browser reopening a session of tabs.
@MainActor let restoreSettle: TimeInterval = 60

/// When restore mode ends, and how many remembered windows are still
/// unclaimed. `nil` deadline = no coordinated restore has run yet. Restore
/// mode is over at the deadline OR once nothing is left to steer, whichever
/// comes first — see `isStartupRestore` in `runCoordinatedRestore`.
@MainActor private var restoreModeDeadline: Date?
@MainActor private var unclaimedRestoreEntries = 0

/// True until the startup restore has run and every remembered window has
/// been claimed (or `restoreSettle` ran out). Persisting in that window would
/// overwrite the remembered workspaces with wherever startup parked windows.
@MainActor
var isRestoringWindowState: Bool {
    guard let deadline = restoreModeDeadline else { return true }
    return unclaimedRestoreEntries > 0 && Date.now < deadline
}

// MARK: - Persisting window state

/// mur — persist EVERYTHING mur needs to rebuild this screen after a
/// restart: each tiled window's cell (`WindowMemory`, keyed by app +
/// title; floating is never persisted), plus each terminal's session
/// (cwd + span, `TerminalSessionStore`).
///
/// Individual commands remember the window they acted on, but a move or a
/// resize renumbers the SIBLINGS' slots too, and a window that just opened
/// can't report its cwd yet. Sweeping the whole layout — after windows open
/// and after every move — keeps the on-disk state matching the screen
/// instead of drifting from it.
@MainActor private var persistWindowStateTask: Task<Void, Never>?

/// Debounced full sweep. Safe to call from every command; the last call in
/// a burst wins.
@MainActor
func persistWindowStateSoon() {
    persistWindowStateTask?.cancel()
    persistWindowStateTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Task.isCancelled { return }
        await persistWindowStateNow()
    }
}

/// Same sweep, repeated on a short ladder. Used right after windows open:
/// a freshly-spawned terminal publishes its cwd (`AXDocument`) well after
/// the window itself exists, so one immediate pass would record the window
/// but not its session — and a session mur never recorded is a session it
/// can't restore, or worse, one it relaunches a duplicate of.
@MainActor
func persistWindowStateAfterOpen() {
    persistWindowStateTask?.cancel()
    persistWindowStateTask = Task { @MainActor in
        for delaySeconds in [1.0, 5.0, 15.0] {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            if Task.isCancelled { return }
            await persistWindowStateNow()
        }
    }
}

@MainActor
func persistWindowStateNow() async {
    for workspace in Workspace.all {
        let layout = workspace.stackingLayout
        for (windowId, span) in layout.placements {
            guard let window = Window.get(byId: windowId) else { continue }
            let title = (try? await window.title) ?? ""
            windowMemory.remember(
                appId: window.app.rawAppBundleId ?? "", title: title,
                workspace: workspace.name, shape: layout.shape, span: span,
            )
        }
    }
    windowMemory.save()
    await captureArrangement()
    await captureAllTerminalSessions()
}
