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

    // mur — FLOAT FIRST, MOUNT A BEAT LATER. A window that opens while mur
    // is already running is left floating exactly where the app put it, and
    // joins the grid from `runCoordinatedRestore` ~90ms later. Mounting it
    // synchronously here means placing it from the sync heuristic (no title
    // available yet), then moving it AGAIN when the async restore reads the
    // title and finds its remembered cell — the double hop is the visible
    // "new window jumps across the screen and lands on top of another one".
    // Deferring collapses that into a single move from the opening position.
    // Startup is exempt: every existing window is registered in one batch
    // there, and floating them all first would just churn the whole screen.
    if !isStartup, case .tilingContainer? = window.parent?.cases {
        pendingGridMountIds.insert(window.windowId)
        window.bindAsFloatingWindow(to: workspace)
        return
    }
    mountInStackingLayout(window, in: workspace)
}

/// mur — windows that opened while mur was running and are waiting to be
/// mounted into the grid by the next coordinated restore. They're bound as
/// floating windows meanwhile, so they render where the app opened them.
@MainActor private var pendingGridMountIds: Set<WindowId> = []

/// Forget a pending mount (the window died before the restore ran).
@MainActor
func forgetPendingGridMount(_ windowId: WindowId) {
    pendingGridMountIds.remove(windowId)
}

/// mur — mount a deferred window into the grid: rebind it to the tiling
/// container it would have been in, then run the regular placement. Returns
/// `false` if this window wasn't deferred (nothing to do).
@MainActor
private func flushPendingGridMount(_ window: Window, in workspace: Workspace) -> Bool {
    guard pendingGridMountIds.remove(window.windowId) != nil else { return false }
    window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    mountInStackingLayout(window, in: workspace)
    return true
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
        unclaimedRestoreEntries = windowMemory.tiledEntryCount()
    }
    let isStartupRestore = unclaimedRestoreEntries > 0
        && Date.now < (restoreModeDeadline ?? .distantPast)

    struct Tiled { let window: Window; let workspace: Workspace; let lane: Int; let slot: Int }
    // Remembered cells still up for grabs, per app — see the fallback below.
    var appSpanPool: [String: [StoredWindowState]] = [:]
    var tiled: [Tiled] = []
    var floaters: [(window: Window, workspace: Workspace)] = []
    // Synthetic lanes for windows sent to their app's workspace without a
    // remembered cell: high enough to rank after every real lane.
    let unrankedLaneBase = Int.max - 1000
    var unrankedCount = 0

    for id in ids {
        guard let window = Window.get(byId: id), let curWs = window.nodeWorkspace else {
            forgetPendingGridMount(id)
            continue
        }
        // mur — a window that opened while mur was running has been floating
        // where the app put it since registration; mount it into the grid
        // now, and seed its last-applied rect with that opening position so
        // the spring animation carries it into its cell instead of the
        // animator treating this as a first placement and snapping.
        if flushPendingGridMount(window, in: curWs) {
            if let opening = try? await window.getAxRect() {
                window.lastAppliedLayoutPhysicalRect = opening
            }
        }
        let appId = window.app.rawAppBundleId ?? ""
        let title = (try? await window.title) ?? ""
        let shape = curWs.stackingLayout.shape
        // mur — A TERMINAL'S TITLE IS NOT AN IDENTITY. Ghostty (with shell
        // integration, and claude on top of it) rewrites the title as work
        // progresses — "◐ Empty columns cleanup" one minute, something else
        // the next — so title-keyed memory misses on almost every restart
        // and the window lands wherever the heuristic puts it: the "windows
        // keep changing position after restore" symptom. The cwd is stable
        // across restarts, so for terminals prefer the remembered session's
        // span. Two terminals in the same cwd resolve to the same cell and
        // become two ROWS of that column (`place` inserts, never overlaps),
        // which is what sharing a repo should look like anyway.
        var recalled = windowMemory.recall(appId: appId, title: title, shape: shape)
        if recalled == nil || recalled?.floating == false,
           sessionRestoreTerminalBundleIds.contains(appId),
           // `resolveTerminalCwd`, not `window.cwd`: a session mur itself
           // relaunched runs `claude` directly, so no shell integration runs
           // and Ghostty NEVER publishes AXDocument for it. Asking the window
           // alone leaves mur's own restored terminals unidentifiable — they
           // miss their session, fall through to the heuristic, and land in
           // whatever workspace happens to be active. Resolving through the
           // spawn record hands them back their remembered workspace + cell.
           let cwd = await resolveTerminalCwd(window),
           let session = terminalSessionStore.recall(cwd: cwd)
        {
            recalled = StoredWindowState(floating: false, span: session.span, workspace: session.workspace)
        }
        // Title miss and no terminal session: fall back to this app's
        // remembered cells, handed out in order so N windows of one app
        // keep their relative columns instead of scattering.
        if recalled == nil {
            let pool = appSpanPool[appId] ?? windowMemory.recallTiledByApp(appId: appId, shape: shape)
            if let next = pool.first {
                appSpanPool[appId] = Array(pool.dropFirst())
                recalled = next
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
            if isStartupRestore,
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
        for lane in layout.usedLanes {
            let hasTerminal = layout.placements.contains { id, span in
                span.lane0 <= lane && lane <= span.lane1
                    && recognizedTerminalBundleIds.contains(Window.get(byId: id)?.app.rawAppBundleId ?? "")
            }
            layout.setLaneAbsoluteWidth(
                hasTerminal ? terminalLaneFraction(for: workspace.workspaceMonitor) : StackingLayout.defaultColumnWidth,
                lane: lane,
            )
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

// MARK: - Persisting window state

/// mur — persist EVERYTHING mur needs to rebuild this screen after a
/// restart: each tiled window's cell and each floating window's mode
/// (`WindowMemory`, keyed by app + title), plus each terminal's session
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
        for window in workspace.children.filterIsInstance(of: Window.self) {
            // A window waiting for its deferred grid mount is floating only
            // for the next few frames — recording that would restore it
            // floating forever.
            if pendingGridMountIds.contains(window.windowId) { continue }
            let title = (try? await window.title) ?? ""
            windowMemory.rememberFloating(
                appId: window.app.rawAppBundleId ?? "", title: title,
                workspace: workspace.name, shape: layout.shape,
            )
        }
    }
    windowMemory.save()
    await captureAllTerminalSessions()
}
