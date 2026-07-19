import AppKit
import Common

@MainActor
private var resizeWithMouseTask: Task<(), any Error>? = nil

func resizedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let windowId = ax.containingWindowId()
    Task { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        // mur — our own animation frames fire resize notifications; ignore
        // them so the animator doesn't trigger a refresh storm.
        if let windowId, WindowAnimator.shared.isDrivingFrame(windowId) { return }
        // mur — self-heal stuck mouse-manipulation state: if the left button
        // is up, no resize/move is in progress, so clear any leftover
        // `currentlyManipulatedWithMouseWindowId` (a missed mouse-up would
        // otherwise block resizing every other window until restart).
        if !isLeftMouseButtonDown { try? await resetManipulatedWithMouseIfPossible() }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        resizeWithMouseTask?.cancel()
        resizeWithMouseTask = Task {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await resizeWithMouse(window)
            }
        }
    }
}

@MainActor
func resetManipulatedWithMouseIfPossible() async throws {
    if currentlyManipulatedWithMouseWindowId != nil {
        currentlyManipulatedWithMouseWindowId = nil
        currentlyResizedWithMouseWindowId = nil
        for workspace in Workspace.all {
            workspace.resetResizeWeightBeforeResizeRecursive()
        }
        scheduleCancellableCompleteRefreshSession(.resetManipulatedWithMouse, optimisticallyPreLayoutWorkspaces: true)
    }
}

private let adaptiveWeightBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "adaptiveWeightBeforeResizeWithMouseKey")

@MainActor
private func resizeWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    guard let parent = window.parent else { return }
    switch parent.cases {
        case .workspace, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Nothing to do for floating, or unconventional windows
        case .tilingContainer:
            guard let rect = try await window.getAxRect() else { return }
            guard let lastAppliedLayoutRect = window.lastAppliedLayoutPhysicalRect else { return }
            // mur — mark the resize in progress so the move handler won't
            // hijack the left/top-edge `kAXMovedNotification` into a drag.
            currentlyResizedWithMouseWindowId = window.windowId
            WindowAnimator.shared.cancel(window.windowId)

            // mur — phase 1.5 grid resize path. When the experimental
            // grid is on AND this window is registered in the workspace's
            // stackingLayout, redistribute slot weights via StackingResize.snap
            // instead of mutating the tree's adaptive weights.
            if config.experimentalStackingLayout,
               let workspace = window.nodeWorkspace,
               workspace.stackingLayout.placements[window.windowId] != nil
            {
                let available = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
                let resolved = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
                let slotGap = CGFloat(resolved.inner.get(
                    workspace.stackingLayout.shape.orientation == .landscape ? .v : .h,
                ))
                let sample = StackingResize.DragSample(
                    layout: workspace.stackingLayout,
                    windowId: window.windowId,
                    lastAppliedRect: lastAppliedLayoutRect,
                    currentRect: rect,
                    available: available,
                    innerGap: slotGap,
                )
                if let result = StackingResize.snap(sample) {
                    if let lane = result.slotLane, let w = result.slotWeights {
                        workspace.stackingLayout.setSlotWeights(lane: lane, weights: w)
                    }
                    if let lw = result.laneWeights {
                        workspace.stackingLayout.setLaneWeights(lw)
                    }
                    // mur — advance the baseline to the currently sampled
                    // rect. The layout pass SKIPS the dragged window
                    // (`currentlyManipulatedWithMouseWindowId`), so it
                    // never updates `lastAppliedLayoutPhysicalRect` for
                    // it. Without this, each AX event recomputes its
                    // delta from the pre-drag rect — consecutive events
                    // would re-apply *cumulative* weight mutations,
                    // producing the "exponential" feedback the user
                    // observed (linear cursor → quadratic redistribution).
                    window.lastAppliedLayoutPhysicalRect = rect
                }
                currentlyManipulatedWithMouseWindowId = window.windowId
                return
            }

            let (lParent, lOwnIndex) = window.closestParent(hasChildrenInDirection: .left, withLayout: .tiles) ?? (nil, nil)
            let (dParent, dOwnIndex) = window.closestParent(hasChildrenInDirection: .down, withLayout: .tiles) ?? (nil, nil)
            let (uParent, uOwnIndex) = window.closestParent(hasChildrenInDirection: .up, withLayout: .tiles) ?? (nil, nil)
            let (rParent, rOwnIndex) = window.closestParent(hasChildrenInDirection: .right, withLayout: .tiles) ?? (nil, nil)
            let table: [(CGFloat, TilingContainer?, Int?, Int?)] = [
                (lastAppliedLayoutRect.minX - rect.minX, lParent, 0,                        lOwnIndex),               // Horizontal, to the left of the window
                (rect.maxY - lastAppliedLayoutRect.maxY, dParent, dOwnIndex.map { $0 + 1 }, dParent?.children.count), // Vertical, to the down of the window
                (lastAppliedLayoutRect.minY - rect.minY, uParent, 0,                        uOwnIndex),               // Vertical, to the up of the window
                (rect.maxX - lastAppliedLayoutRect.maxX, rParent, rOwnIndex.map { $0 + 1 }, rParent?.children.count), // Horizontal, to the right of the window
            ]
            for (diff, parent, startIndex, pastTheEndIndex) in table {
                if let parent, let startIndex, let pastTheEndIndex, pastTheEndIndex - startIndex > 0 && abs(diff) > 5 { // 5 pixels should be enough to fight with accumulated floating precision error
                    let siblingDiff = diff.div(pastTheEndIndex - startIndex).orDie()
                    let orientation = parent.orientation

                    window.parentsWithSelf.lazy
                        .prefix(while: { $0 != parent })
                        .filter {
                            let parent = $0.parent as? TilingContainer
                            return parent?.orientation == orientation && parent?.layout == .tiles
                        }
                        .forEach { $0.setWeight(orientation, $0.getWeightBeforeResize(orientation) + diff) }
                    for sibling in parent.children[startIndex ..< pastTheEndIndex] {
                        sibling.setWeight(orientation, sibling.getWeightBeforeResize(orientation) - siblingDiff)
                    }
                }
            }
            currentlyManipulatedWithMouseWindowId = window.windowId
    }
}

extension TreeNode {
    @MainActor
    fileprivate func getWeightBeforeResize(_ orientation: Orientation) -> CGFloat {
        let currentWeight = getWeight(orientation) // Check assertions
        return getUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
            ?? (lastAppliedLayoutVirtualRect?.getDimension(orientation) ?? currentWeight)
            .also { putUserData(key: adaptiveWeightBeforeResizeWithMouseKey, data: $0) }
    }

    fileprivate func resetResizeWeightBeforeResizeRecursive() {
        cleanUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
        for child in children {
            child.resetResizeWeightBeforeResizeRecursive()
        }
    }
}
