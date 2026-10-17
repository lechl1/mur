import AppKit
import Common

@MainActor
private var activeRefreshTask: Task<(), any Error>? = nil

/// mur — the event that arrived while a refresh was already running, kept
/// so exactly one follow-up runs when that refresh finishes. See
/// `scheduleCancellableCompleteRefreshSession`.
@MainActor
private var pendingRefresh: (event: RefreshSessionEvent, preLayout: Bool)? = nil

/// mur — identifies the refresh currently registered in
/// `activeRefreshTask`, so a task that finishes late can tell whether that
/// slot is still its own. `runLightSession` clears the slot from the
/// outside while the task it cancelled is still unwinding; without the id
/// that task's cleanup would clear a NEWER refresh's registration and let
/// two run at once.
@MainActor
private var activeRefreshId: UInt64 = 0

/// mur — COALESCE, DON'T PREEMPT.
///
/// This used to be `activeRefreshTask?.cancel()` followed by a fresh
/// `Task`: every incoming event threw away the refresh in flight. That
/// starves under mur's own feedback loop — a refresh calls `setAxFrame`,
/// macOS answers with `AXMoved` / `AXResized`, those schedule a refresh,
/// which cancels the one still laying windows out, which on its way out
/// emits more frames. Measured on a live session, **every** background
/// refresh ended in `CancellationError`, some after 1ms, so
/// `pruneStackingLayout` never ran: a closed window kept its column and
/// the survivors never grew into the freed space, until any CLI command
/// (which runs a NON-cancellable session) happened to poke the daemon.
/// That is the "closing a window doesn't resize the others" bug, and the
/// same starvation is why a mouse-displaced window used to hang around
/// off-grid.
///
/// So a refresh now runs to completion and anything that arrives meanwhile
/// is remembered as ONE follow-up, which starts when it finishes. The
/// follow-up keeps the newest event, since refreshes are idempotent — the
/// state is recomputed from scratch, not accumulated. The loop terminates
/// because a refresh that changes nothing emits no notifications.
///
/// `runLightSession` still cancels: an explicit command outranks a
/// background refresh, and it re-schedules one on its own way out.
@MainActor
func scheduleCancellableCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) {
    if activeRefreshTask != nil {
        pendingRefresh = (event, optimisticallyPreLayoutWorkspaces)
        return
    }
    activeRefreshId &+= 1
    let id = activeRefreshId
    activeRefreshTask = Task { @MainActor in
        defer {
            if activeRefreshId == id {
                activeRefreshTask = nil
                if let next = pendingRefresh {
                    pendingRefresh = nil
                    scheduleCancellableCompleteRefreshSession(
                        next.event,
                        optimisticallyPreLayoutWorkspaces: next.preLayout,
                    )
                }
            }
        }
        try checkCancellation()
        await runHeavyCompleteRefreshSession(
            event,
            cancellable: true,
            optimisticallyPreLayoutWorkspaces: optimisticallyPreLayoutWorkspaces,
        )
    }
}

@MainActor
func runHeavyCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    cancellable: Bool,
    layoutWorkspaces shouldLayoutWorkspaces: Bool = true,
    optimisticallyPreLayoutWorkspaces: Bool = false,
) async {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    if !TrayMenuModel.shared.isEnabled { return }
    let res = await Result {
        try await $refreshSessionEvent.withValue(event) {
            try await $_isStartup.withValue(event.isStartup) {
                // mur — same fallback as runLightSession: a slow AX
                // (Chromium etc.) shouldn't crash the heavy refresh.
                let nativeFocused: Window?
                do {
                    nativeFocused = try await getNativeFocusedWindow()
                } catch is FocusedWindowTimeoutError {
                    nativeFocused = focus.windowOrNil
                }
                if let nativeFocused { try await debugWindowsIfRecording(nativeFocused) }
                updateFocusCache(nativeFocused)

                if shouldLayoutWorkspaces && optimisticallyPreLayoutWorkspaces { try await layoutWorkspaces() }

                refreshModel()
                try await refresh()
                gcMonitors()

                updateTrayText()
                SecureInputPanel.shared.refresh()
                try await normalizeLayoutReason()
                if shouldLayoutWorkspaces { try await layoutWorkspaces() }
            }
        }
    }
    switch res {
        case .success(()): break
        case .failure(let err as CancellationError): check(cancellable, "Non cancellable refresh session was canceled: \(err) (\(type(of: err)))")
        case .failure(let err): die("Illegal error: \(err)")
    }
}

@MainActor
func runLightSession<T>(
    _ event: RefreshSessionEvent,
    _: RunSessionGuard,
    body: @MainActor () async throws -> T,
) async throws -> T {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    activeRefreshTask?.cancel() // Give priority to runSession
    activeRefreshTask = nil
    // mur — the cancelled refresh must not run its own follow-up, and must
    // not clear whatever registers itself next.
    activeRefreshId &+= 1
    pendingRefresh = nil
    return try await $refreshSessionEvent.withValue(event) {
        try await $_isStartup.withValue(event.isStartup) {
            // mur — distinguish "AX timed out" from "really no focused
            // window". On timeout, fall back to the cached `focus` so
            // keybindings keep working when the frontmost app's AX is
            // slow (Chromium, Godot, …).
            let nativeFocused: Window?
            do {
                nativeFocused = try await getNativeFocusedWindow()
            } catch is FocusedWindowTimeoutError {
                nativeFocused = focus.windowOrNil
            }
            if let nativeFocused { try await debugWindowsIfRecording(nativeFocused) }
            updateFocusCache(nativeFocused)
            let focusBefore = focus.windowOrNil

            refreshModel()
            let result = try await body()
            refreshModel()

            let focusAfter = focus.windowOrNil

            updateTrayText()
            SecureInputPanel.shared.refresh()
            try await layoutWorkspaces()
            if focusBefore != focusAfter {
                focusAfter?.nativeFocus() // syncFocusToMacOs
            }
            scheduleCancellableCompleteRefreshSession(event)
            return result
        }
    }
}

struct RunSessionGuard: Sendable {
    @MainActor
    static var isServerEnabled: RunSessionGuard? { TrayMenuModel.shared.isEnabled ? forceRun : nil }
    @MainActor
    static func isServerEnabled(orIsEnableCommand command: (any Command)?) -> RunSessionGuard? {
        command is EnableCommand ? .forceRun : .isServerEnabled
    }
    @MainActor
    static func checkServerIsEnabledOrDie(
        file: StaticString = #fileID,
        line: Int = #line,
        column: Int = #column,
        function: String = #function,
    ) -> RunSessionGuard {
        .isServerEnabled ?? dieT("server is disabled", file: file, line: line, column: column, function: function)
    }
    static let forceRun = RunSessionGuard()
    private init() {}
}

@MainActor
func refreshModel() {
    Workspace.garbageCollectUnusedWorkspaces()
    checkOnFocusChangedCallbacks()
    normalizeContainers()
}

@MainActor
private func refresh() async throws {
    // Garbage collect terminated apps and windows before working with all windows
    let mapping = try await MacApp.refreshAllAndGetAliveWindowIds(frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    let aliveWindowIds = mapping.values.flatMap(id).toSet()

    for window in MacWindow.allWindows {
        if !aliveWindowIds.contains(window.windowId) {
            window.garbageCollect(skipClosedWindowsCache: false)
        }
    }
    for (app, windowIds) in mapping {
        for windowId in windowIds {
            try await MacWindow.getOrRegister(windowId: windowId, macApp: app)
        }
    }

    // Garbage collect workspaces after apps, because workspaces contain apps.
    Workspace.garbageCollectUnusedWorkspaces()
}

func refreshObs(_: AXObserver, element: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    var pid: pid_t = 0
    let isDestroy = notif == kAXUIElementDestroyedNotification as String
    let isCreate = notif == kAXWindowCreatedNotification as String
    if isDestroy || isCreate { AXUIElementGetPid(element, &pid) }
    Task { @MainActor in
        if !TrayMenuModel.shared.isEnabled { return }
        if isDestroy || isCreate, pid != 0 { await syncWindowsOfApp(pid: pid) }
        scheduleCancellableCompleteRefreshSession(.ax(notif))
    }
}

/// mur — fast path for a window opening or closing: query only the app that
/// reported it, register its new windows, garbage-collect its dead ones and
/// re-layout, instead of waiting for the full refresh to hear back from every
/// app. The full refresh still follows. Skipped while a refresh is in flight
/// so the two never interleave.
@MainActor
private func syncWindowsOfApp(pid: pid_t) async {
    guard activeRefreshTask == nil else { return }
    guard let (app, ids) = try? await MacApp.refreshAliveWindowIds(ofPid: pid), activeRefreshTask == nil else { return }
    let alive = ids.toSet()
    var changed = false
    for window in MacWindow.allWindows where window.macApp == app && !alive.contains(window.windowId) {
        window.garbageCollect(skipClosedWindowsCache: false)
        changed = true
    }
    for windowId in ids where Window.get(byId: windowId) == nil {
        if (try? await MacWindow.getOrRegister(windowId: windowId, macApp: app)) != nil { changed = true }
    }
    if changed {
        refreshModel()
        try? await layoutWorkspaces()
    }
}

enum OptimalHideCorner {
    case bottomLeftCorner, bottomRightCorner
}

@MainActor
func layoutWorkspaces() async throws {
    if !TrayMenuModel.shared.isEnabled {
        for workspace in Workspace.all {
            workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
            try await workspace.layoutWorkspace() // Unhide tiling windows from corner
        }
        return
    }
    let monitors = monitors
    var monitorToOptimalHideCorner: [CGPoint: OptimalHideCorner] = [:]
    for monitor in monitors {
        let xOff = monitor.width * 0.1
        let yOff = monitor.height * 0.1
        // brc = bottomRightCorner
        let brc1 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: -yOff)
        let brc2 = monitor.rect.bottomRightCorner + CGPoint(x: -xOff, y: 2)
        let brc3 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: 2)

        // blc = bottomLeftCorner
        let blc1 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: -yOff)
        let blc2 = monitor.rect.bottomLeftCorner + CGPoint(x: xOff, y: 2)
        let blc3 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: 2)

        func contains(_ monitor: Monitor, _ point: CGPoint) -> Int { monitor.rect.contains(point) ? 1 : 0 }
        let important = 10

        let corner: OptimalHideCorner =
            monitors.sumOfInt { contains($0, blc1) + contains($0, blc2) + important * contains($0, blc3) } <
            monitors.sumOfInt { contains($0, brc1) + contains($0, brc2) + important * contains($0, brc3) }
            ? .bottomLeftCorner
            : .bottomRightCorner
        monitorToOptimalHideCorner[monitor.rect.topLeftCorner] = corner
    }

    // to reduce flicker, first unhide visible workspaces, then hide invisible ones
    for monitor in monitors {
        let workspace = monitor.activeWorkspace
        workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
        try await workspace.layoutWorkspace()
    }
    for workspace in Workspace.all where !workspace.isVisible {
        let corner = monitorToOptimalHideCorner[workspace.workspaceMonitor.rect.topLeftCorner] ?? .bottomRightCorner
        // mur — size the tiled windows to their cells BEFORE hiding them. A
        // window sent here keeps its old size while hidden and is only
        // resized once the workspace is visited, so the grid looked misaligned
        // until then. Position stays in the corner; only the size is applied.
        if config.experimentalStackingLayout {
            let slotGap: CGFloat = 0 // gaps are corrected by the real layout on the first visit
            let rect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
            for windowId in workspace.stackingLayout.zOrder {
                guard let window = Window.get(byId: windowId), window.nodeWorkspace === workspace,
                      let r = workspace.stackingLayout.resolveRect(for: windowId, in: rect, innerGap: slotGap),
                      window.lastAppliedLayoutPhysicalRect?.size != r.size else { continue }
                window.setAxFrame(nil, r.size)
                window.lastAppliedLayoutPhysicalRect = r
            }
        }
        for window in workspace.allLeafWindowsRecursive {
            try await (window as! MacWindow).hideInCorner(corner) // todo as!
        }
    }
}

@MainActor
private func normalizeContainers() {
    // Can't do it only for visible workspace because most of the commands support --window-id and --workspace flags
    for workspace in Workspace.all {
        workspace.normalizeContainers()
    }
}
