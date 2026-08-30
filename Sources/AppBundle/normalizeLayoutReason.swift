import Foundation

/// mur — windows mur itself minimized on purpose (`macos-native-minimize`).
/// Auto-restore leaves these alone: an explicit request wins over the
/// keep-columns-full policy.
@MainActor var intentionallyMinimizedWindowIds: Set<UInt32> = []

/// mur — when the first auto-restore attempt was issued, per window.
@MainActor private var unminimizeAttemptedAt: [UInt32: Date] = [:]

/// How long to keep re-issuing the un-minimize request before accepting
/// that the app really does want its window minimized. Some apps (and
/// the Dock genie animation) take a beat to come back.
private let autoUnminimizeGiveUpAfter: TimeInterval = 2

/// Forget both bits of per-window minimize state. Called when a window
/// dies and whenever it's observed un-minimized.
@MainActor
func forgetMinimizeState(of windowId: UInt32) {
    unminimizeAttemptedAt.removeValue(forKey: windowId)
    intentionallyMinimizedWindowIds.remove(windowId)
}

@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self))
    try await validateStillPopups()
}

@MainActor
private func validateStillPopups() async throws {
    for node in macosPopupWindowsContainer.children {
        let popup = (node as! MacWindow)
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await popup.isWindowHeuristic(windowLevel) {
            try await popup.relayoutWindow(on: focus.workspace)
            try await tryOnWindowDetected(popup)
        }
    }
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window]) async throws {
    for window in windows {
        let isMacosFullscreen = try await window.isMacosFullscreen
        let isMacosMinimized = try await (!isMacosFullscreen).andAsync { @MainActor @Sendable in try await window.isMacosMinimized }
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden
        if !isMacosMinimized { forgetMinimizeState(of: window.windowId) }
        switch window.layoutReason {
            case .standard:
                guard let parent = window.parent else { continue }
                switch true {
                    case isMacosFullscreen:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                        dropFromStackingLayout(window, in: workspace)
                    case isMacosMinimized:
                        // mur — keep grid windows visible. A window minimized
                        // out from under us (⌘M, or an app minimizing itself)
                        // would leave its column standing empty. Restore it
                        // instead and keep its cell; only give up — falling
                        // through to the regular minimized handling below —
                        // if it's still minimized `autoUnminimizeGiveUpAfter`
                        // after the first attempt.
                        if tryAutoUnminimize(window, in: workspace) { break }
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                        dropFromStackingLayout(window, in: workspace)
                    case isMacosWindowOfHiddenApp:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                        dropFromStackingLayout(window, in: workspace)
                    default: break
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace)
                }
        }
    }
}

@MainActor
func exitMacOsNativeUnconventionalState(window: Window, prevParentKind: NonLeafTreeNodeKind, workspace: Workspace) async throws {
    window.layoutReason = .standard
    switch prevParentKind {
        case .workspace:
            window.bindAsFloatingWindow(to: workspace)
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, forceTile: true)
            // mur — the window was dropped from the grid when it entered the
            // unconventional state (see `dropFromStackingLayout`). Now that
            // it's a tiled window again, rejoin the grid so it reclaims a
            // lane / slot instead of leaving a hole behind it.
            tryRegisterInStackingLayout(window)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace)
    }
}

/// mur — when a grid-managed window enters a macOS-native unconventional
/// state (minimized / fullscreen / hidden app), it's rebound into a shim
/// container but would otherwise keep reserving its lane / slot in the
/// `StackingLayout`, leaving a visible gap with no window in it. Drop it
/// from the grid so `compactGaps()` collapses the freed cell. It rejoins
/// the grid via `tryRegisterInStackingLayout` when it returns to standard
/// layout. No-op when the grid is off or the window wasn't in it.
@MainActor
private func dropFromStackingLayout(_ window: Window, in workspace: Workspace) {
    guard config.experimentalStackingLayout else { return }
    _ = workspace.stackingLayout.remove(window.windowId)
    // The minimized-windows container is global, so the workspace passed in
    // isn't necessarily the one holding the window's cell (see the
    // `focus.workspace` call site in `normalizeLayoutReason`). Sweep the
    // rest so a stale cell can't keep a column alive on another workspace.
    for other in Workspace.all where other != workspace {
        if other.stackingLayout.placements[window.windowId] != nil {
            _ = other.stackingLayout.remove(window.windowId)
        }
    }
}

/// mur — restore a grid-managed window that was minimized behind mur's
/// back, so its column doesn't render empty. Returns `true` while the
/// restore is still being attempted (the caller then leaves the window in
/// the grid); `false` means "let it minimize" — either it isn't ours to
/// keep, mur minimized it on purpose, or the app kept it minimized past
/// `autoUnminimizeGiveUpAfter`.
@MainActor
private func tryAutoUnminimize(_ window: Window, in workspace: Workspace) -> Bool {
    guard config.experimentalStackingLayout else { return false }
    guard !intentionallyMinimizedWindowIds.contains(window.windowId) else { return false }
    // Only windows that own a cell: a floating window leaves no gap behind.
    guard workspace.stackingLayout.placements[window.windowId] != nil else { return false }
    let now = Date.now
    let firstAttempt = unminimizeAttemptedAt[window.windowId] ?? now
    unminimizeAttemptedAt[window.windowId] = firstAttempt
    guard now.timeIntervalSince(firstAttempt) < autoUnminimizeGiveUpAfter else { return false }
    window.asMacWindow().setNativeMinimized(false)
    return true
}
