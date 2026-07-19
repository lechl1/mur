import AppKit
import Common

@MainActor
private var moveWithMouseTask: Task<(), any Error>? = nil

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    let notif = notif as String
    Task { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        // mur — ignore move notifications from our own animation frames.
        if let windowId, WindowAnimator.shared.isDrivingFrame(windowId) { return }
        // mur — self-heal stuck manipulation state when the button is up.
        if !isLeftMouseButtonDown { try? await resetManipulatedWithMouseIfPossible() }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
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
    let layout = workspace.stackingLayout
    guard let source = layout.placements[window.windowId] else { return }
    let available = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
    let resolved = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
    let slotGap = CGFloat(resolved.inner.get(
        layout.shape.orientation == .landscape ? .v : .h,
    ))
    let hoverCell = layout.cellAt(point: mouseLocation, in: available, innerGap: slotGap)
    gridDragSession = StackingDragSession(
        windowId: window.windowId,
        workspace: workspace,
        sourceSpan: source,
        hoverCell: hoverCell,
    )
    StackingHud.shared.update(layout: layout, span: source, hoverSpan: hoverCell.map {
        TileSpan(lane0: $0.lane, lane1: $0.lane, slot0: $0.slot, slot1: $0.slot)
    })
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
