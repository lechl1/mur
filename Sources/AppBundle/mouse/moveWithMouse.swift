import AppKit
import Common

@MainActor
private var moveWithMouseTask: Task<(), any Error>? = nil

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    let notif = notif as String
    fireAndForget { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        // mur — ignore move notifications from our own animation frames.
        if let windowId, WindowAnimator.shared.isDrivingFrame(windowId) { return }
        // mur — self-heal stuck manipulation state when the button is up.
        if !isLeftMouseButtonDown { try? await resetManipulatedWithMouseIfPossible() }
        let window = windowId.flatMap { Window.get(byId: $0) }
        // mur — THE REFRESH MUST HAPPEN EVEN IF THE CHECK FAILS. This used
        // to read `try await isManipulatedWithMouse(window)` inside the
        // guard's condition: when one of its AX reads threw — a slow app, a
        // cancelled session — the whole closure unwound before reaching the
        // `else`, so no refresh was scheduled and the window was simply
        // left wherever it had been dragged to. `try?` turns a failed check
        // into "not a mouse drag", which schedules the refresh that snaps
        // the window back into its cell.
        let manipulated = if let window { (try? await isManipulatedWithMouse(window)) ?? false } else { false }
        guard let windowId, let window, manipulated else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        moveWithMouseTask?.cancel()
        moveWithMouseTask = Task {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await moveWithMouse(window)
            }
        }
    }
}

@MainActor
private func moveWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    // mur — stacking-aware drag. If the experimental grid is on AND this
    // window is registered in some workspace's stackingLayout, run the grid
    // hover/snap path INSTEAD of the AeroSpace tree swap. The HUD shows
    // a hover preview; the global mouse-up handler does the actual snap.
    if config.experimentalStackingLayout,
       let workspace = window.nodeWorkspace,
       workspace.stackingLayout.placements[window.windowId] != nil
    {
        // mur — dragging the LEFT or TOP edge fires kAXMovedNotification
        // too (position changes alongside size). If a resize gesture is
        // already in progress for this window, never hijack it into a
        // move / grid drag-session — that would null the resize baseline
        // and snap the window back on mouse-up. This flag is authoritative
        // once the first resize event has landed; the size comparison
        // below still catches the very first event (before the flag is
        // set), when `lastAppliedLayoutPhysicalRect` is still pristine.
        if currentlyResizedWithMouseWindowId == window.windowId {
            return
        }
        if let lastRect = window.lastAppliedLayoutPhysicalRect,
           let currentRect = try await window.getAxRect(),
           abs(currentRect.width - lastRect.width) > 1 ||
           abs(currentRect.height - lastRect.height) > 1
        {
            return
        }
        moveStackingWindow(window, workspace: workspace)
        return
    }
    // mur — a window outside the grid (floated as "non-resizable", or in the
    // tree without a cell) dragged onto another monitor moves there the way
    // `move-node-to-workspace` does, which tiles everything not floating by
    // design. The tree paths below only rebound it, so it never tiled there.
    if config.experimentalStackingLayout, let workspace = window.nodeWorkspace,
       window.parent is Workspace || window.parent is TilingContainer
    {
        let target = mouseLocation.monitorApproximation.activeWorkspace
        if target != workspace {
            currentlyManipulatedWithMouseWindowId = window.windowId
            // Asked once per drag: the heuristic reads AX, and a drag fires
            // a move notification per frame.
            let tile = if let session = gridDragSession, session.windowId == window.windowId {
                session.tile
            } else {
                await !floatsByDesign(window)
            }
            gridDragSession = StackingDragSession(
                windowId: window.windowId,
                workspace: workspace,
                targetWorkspace: target,
                hoverCell: hoverCell(in: target),
                tile: tile,
            )
            return
        }
        if gridDragSession?.windowId == window.windowId { gridDragSession = nil }
    }
    guard let parent = window.parent else { return }
    switch parent.cases {
        case .workspace:
            try await moveFloatingWindow(window)
        case .tilingContainer:
            moveTilingWindow(window)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Unconventional windows can't be moved with mouse
    }
}

@MainActor
private func moveStackingWindow(_ window: Window, workspace: Workspace) {
    currentlyManipulatedWithMouseWindowId = window.windowId
    WindowAnimator.shared.cancel(window.windowId)
    window.lastAppliedLayoutPhysicalRect = nil
    guard let source = workspace.stackingLayout.placements[window.windowId] else { return }
    // mur — hit-test the grid of the monitor the MOUSE is on, not the
    // window's own: `cellAt` clamps an outside point to the last column,
    // so a drop on the other monitor used to snap back home.
    let target = mouseLocation.monitorApproximation.activeWorkspace
    let layout = target.stackingLayout
    let hoverCell = hoverCell(in: target)
    gridDragSession = StackingDragSession(
        windowId: window.windowId,
        workspace: workspace,
        targetWorkspace: target,
        hoverCell: hoverCell,
    )
    let hoverSpan = hoverCell.map { TileSpan.single(lane: $0.lane, slot: $0.slot) }
    if target == workspace {
        StackingHud.shared.update(layout: layout, span: source, hoverSpan: hoverSpan)
    } else if let hoverSpan {
        StackingHud.shared.update(layout: layout, span: hoverSpan, hoverSpan: hoverSpan)
    }
}

/// A dialog, or an app that floats by default: it stays floating wherever
/// it's dragged. An unanswered AX read counts as one, the safe guess.
@MainActor
private func floatsByDesign(_ window: Window) async -> Bool {
    if let appId = window.app.rawAppBundleId, floatByDefaultBundleIds.contains(appId) { return true }
    guard let window = window as? MacWindow else { return false }
    return (try? await window.isDialogHeuristic(getWindowLevel(for: window.windowId))) ?? true
}

/// The cell of `workspace`'s grid under the mouse; nil when that grid is empty.
@MainActor
private func hoverCell(in workspace: Workspace) -> (lane: Int, slot: Int)? {
    let layout = workspace.stackingLayout
    let available = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
    let resolved = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
    let slotGap = CGFloat(resolved.inner.get(
        layout.shape.orientation == .landscape ? .v : .h,
    ))
    return layout.cellAt(point: mouseLocation, in: available, innerGap: slotGap)
}

@MainActor
private func moveFloatingWindow(_ window: Window) async throws {
    guard let targetWorkspace = try await window.getCenter()?.monitorApproximation.activeWorkspace else { return }
    guard let parent = window.parent else { return }
    if targetWorkspace != parent {
        window.bindAsFloatingWindow(to: targetWorkspace)
    }
}

@MainActor
private func moveTilingWindow(_ window: Window) {
    currentlyManipulatedWithMouseWindowId = window.windowId
    window.lastAppliedLayoutPhysicalRect = nil
    let mouseLocation = mouseLocation
    let targetWorkspace = mouseLocation.monitorApproximation.activeWorkspace
    let swapTarget = mouseLocation.findIn(tree: targetWorkspace.rootTilingContainer, virtual: false)?.takeIf { $0 != window }
    if targetWorkspace != window.nodeWorkspace { // Move window to a different monitor
        let index: Int = if let swapTarget, let parent = swapTarget.parent as? TilingContainer, let targetRect = swapTarget.lastAppliedLayoutPhysicalRect {
            mouseLocation.getProjection(parent.orientation) >= targetRect.center.getProjection(parent.orientation)
                ? swapTarget.ownIndex.orDie() + 1
                : swapTarget.ownIndex.orDie()
        } else {
            0
        }
        window.bind(
            to: swapTarget?.parent ?? targetWorkspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: index,
        )
    } else if let swapTarget {
        swapWindows(window, swapTarget)
    }
}

@MainActor
func swapWindows(_ window1: Window, _ window2: Window) {
    if window1 == window2 { return }
    guard let index1 = window1.ownIndex else { return }
    guard let index2 = window1.ownIndex else { return }

    if index1 < index2 {
        let binding2 = window2.unbindFromParent()
        let binding1 = window1.unbindFromParent()

        window2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
        window1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
    } else {
        let binding1 = window1.unbindFromParent()
        let binding2 = window2.unbindFromParent()

        window1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
        window2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    }
}

extension CGPoint {
    @MainActor
    func findIn(tree: TilingContainer, virtual: Bool) -> Window? {
        let point = self
        let target: TreeNode? = switch tree.layout {
            case .tiles:
                tree.children.first(where: {
                    (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
                })
            case .accordion:
                tree.mostRecentChild
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): findIn(tree: container, virtual: virtual)
        }
    }
}
