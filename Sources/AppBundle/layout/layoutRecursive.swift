import AppKit

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws {
        // mur — phase 1.3. When the experimental grid is enabled AND it
        // owns at least one window, dispatch to the grid path. Otherwise
        // fall through to the existing tree-based layout. This means the
        // tree continues to drive layout for any pre-existing windows
        // that haven't been migrated into the grid yet.
        if config.experimentalStackingLayout && !stackingLayout.isEmpty {
            try await layoutWorkspaceWithStacking()
            return
        }
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, LayoutContext(self))
    }

    /// mur — phase 1.3 stacking-based layout dispatch.
    ///
    /// Walks `stackingLayout.zOrder` back→front and `setAxFrame`s each tiled
    /// window to the rect resolved from its `TileSpan`. Floating windows
    /// (direct Window children of this Workspace) are then laid out by
    /// the existing path. The tree (`rootTilingContainer`) is dormant
    /// when this method runs.
    ///
    /// Z-order: setAxFrame doesn't control front-to-back ordering on its
    /// own; that's a focus/raise concern handled when a window is
    /// promoted in `stackingLayout`. This function only places geometry.
    @MainActor
    fileprivate func layoutWorkspaceWithStacking() async throws {
        let context = LayoutContext(self)
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // Reshape if monitor orientation has changed since last layout.
        let mon = rect
        let nowOrientation = LayoutOrientation.forMonitor(width: mon.width, height: mon.height)
        if nowOrientation != stackingLayout.shape.orientation {
            _ = stackingLayout.reshape(to: LayoutShape(orientation: nowOrientation, lanes: stackingLayout.shape.lanes))
        }
        // Single-axis inner gap for now (slot axis). Lane-axis gap is
        // a refinement for a later commit; in the meantime, slots and
        // lanes share the same gap for visual consistency.
        let slotGap = CGFloat(context.resolvedGaps.inner.get(
            stackingLayout.shape.orientation == .landscape ? .v : .h
        ))

        // mur — forced-resize pre-pass. Grow the lane / slot to fit
        // the cached observed minimum so the upcoming setAxFrame
        // produces the correct rect first time.
        //   - Lane-axis grow runs for EVERY window (grow-only): a shared
        //     column grows to its widest window's min width, so every
        //     window in the column fills that width instead of leaving a
        //     window that can't shrink wider than its column-mates.
        //   - Slot-axis grow runs regardless of lane occupancy: when a
        //     window moves up/down in landscape (or left/right in
        //     portrait) within a column with neighbors, the focused
        //     slot still grows to its observed min and the neighbour
        //     slots shrink proportionally.
        let isLandscape = stackingLayout.shape.orientation == .landscape
        for windowId in stackingLayout.zOrder {
            guard Window.get(byId: windowId) != nil,
                  let span = stackingLayout.placements[windowId],
                  let minSize = stackingLayout.observedMinSizes[windowId] else { continue }
            if windowId == currentlyManipulatedWithMouseWindowId { continue }
            let used = stackingLayout.usedLanes
            let totalLaneGap = max(0, CGFloat(used.count - 1)) * slotGap
            let usableLanePx = (isLandscape ? rect.width : rect.height) - totalLaneGap
            let slots = stackingLayout.slotCount(in: span.lane0)
            let totalSlotGap = max(0, CGFloat(slots - 1)) * slotGap
            let usableSlotPx = (isLandscape ? rect.height : rect.width) - totalSlotGap
            let minLanePx = isLandscape ? minSize.width : minSize.height
            let minSlotPx = isLandscape ? minSize.height : minSize.width
            // Grow the column to fit this window's min width. `growLaneToFit`
            // is grow-only, so across all windows in a shared column the lane
            // ends up at the WIDEST window's min — every window in the column
            // then fills that width (a window that can't shrink no longer
            // leaves its column-mates narrower than itself).
            _ = stackingLayout.growLaneToFit(requiredPx: minLanePx, lane: span.lane0, totalUsablePx: usableLanePx)
            _ = stackingLayout.growSlotToFit(requiredPx: minSlotPx, lane: span.lane0, slot: span.slot0, totalUsablePx: usableSlotPx)
        }

        for windowId in stackingLayout.zOrder {
            guard let window = Window.get(byId: windowId) else { continue }
            if window.windowId == currentlyManipulatedWithMouseWindowId { continue }
            guard let r = stackingLayout.resolveRect(for: windowId, in: rect, innerGap: slotGap) else { continue }
            // mur — spring-animate toward the target rect (naru feel). The
            // animator drives per-frame setAxFrames itself and suppresses the
            // resulting AX-notification refreshes via `animatingIds`.
            let previous = window.lastAppliedLayoutPhysicalRect
            window.lastAppliedLayoutVirtualRect = r
            WindowAnimator.shared.animate(window, from: previous, to: r)
            window.lastAppliedLayoutPhysicalRect = r

            // mur — auto-float non-resizable windows. Once per window:
            // wait briefly for the resize to settle, then compare the
            // actual rect against what we asked for. If both dims differ
            // by more than 150px, the app has a fixed window size we
            // can't tile — float it. Threshold accommodates min-size
            // constraints that narrow ONE dimension only.
            if !stackingLayout.verifiedResizableWindows.contains(windowId)
                && !stackingLayout.nonResizableWindows.contains(windowId)
            {
                let workspace = self
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    // Skip while the animator is still driving this window —
                    // its live rect is mid-flight, not the applied target.
                    if WindowAnimator.shared.isDrivingFrame(windowId) { return }
                    guard let actual = try? await window.getAxRect() else { return }
                    let widthDiff = abs(actual.width - r.width)
                    let heightDiff = abs(actual.height - r.height)
                    if widthDiff > 150 && heightDiff > 150 {
                        workspace.stackingLayout.nonResizableWindows.insert(windowId)
                        // Remember the app bundle so future windows of
                        // the same app skip grid registration entirely
                        // and open as floating.
                        let appId = window.app.rawAppBundleId ?? ""
                        if !appId.isEmpty { knownNonResizableAppIds.insert(appId) }
                        _ = workspace.stackingLayout.remove(windowId)
                        window.bindAsFloatingWindow(to: workspace)
                        let monRect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
                        let cx = monRect.topLeftX + (monRect.width - actual.width) / 2
                        let cy = monRect.topLeftY + (monRect.height - actual.height) / 2
                        window.setAxFrame(CGPoint(x: cx, y: cy), actual.size)
                        // Persist floating so a restart restores it floating.
                        let title = (try? await window.title) ?? ""
                        windowMemory.rememberFloating(appId: appId, title: title, shape: workspace.stackingLayout.shape)
                        windowMemory.save()
                    } else {
                        workspace.stackingLayout.verifiedResizableWindows.insert(windowId)
                    }
                }
            }
            // mur — debounced fit-check. Records the observed min size
            // + grows the lane / slot if it overflowed. The pre-pass
            // on the next layout uses the cached size for an instant
            // correct fit. Both axes grow for every window (grow-only),
            // so a shared column settles at its widest window's min width.
            if stackingLayout.placements[windowId] != nil {
                scheduleStackingFitCheck(window: window, requested: r, workspace: self, slotGap: slotGap)
            }
        }
        for window in children.filterIsInstance(of: Window.self) {
            window.lastAppliedLayoutPhysicalRect = nil
            window.lastAppliedLayoutVirtualRect = nil
            try await window.layoutFloatingWindow(context)
        }
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                for window in workspace.children.filterIsInstance(of: Window.self) {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    try await window.layoutFloatingWindow(context)
                }
            case .window(let window):
                if window.windowId != currentlyManipulatedWithMouseWindowId {
                    lastAppliedLayoutVirtualRect = virtual
                    if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        lastAppliedLayoutPhysicalRect = physicalRect
                        window.isFullscreen = false
                        window.setAxFrame(point, CGSize(width: width, height: height))
                    }
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                switch container.layout {
                    case .tiles:
                        try await container.layoutTiles(point, width: width, height: height, virtual: virtual, context)
                    case .accordion:
                        try await container.layoutAccordion(point, width: width, height: height, virtual: virtual, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

// MARK: - Debounced fit-check (forced resize)

@MainActor private var gridFitCheckTasks: [WindowId: Task<Void, Never>] = [:]

/// Lazily verify that a tile fits its window's actual rect. Cancels
/// any pending check for the same window, schedules a fresh one 20ms
/// out, and on fire reads `getAxRect`, caches the observed min size,
/// and grows the lane / slot via `growLaneToFit` / `growSlotToFit`
/// if either dimension is over by more than 20px.
///
/// Lane-axis grow (grow-only) runs for every window, so a shared column
/// grows to its widest window's min width and every window in it fills
/// that width. Slot-axis grow runs regardless of lane
/// occupancy: when a window moves up/down in a populated column
/// (landscape) or left/right in a populated row (portrait), the
/// focused slot grows to its observed min and the neighbour slots
/// shrink proportionally.
@MainActor
fileprivate func scheduleStackingFitCheck(window: Window, requested r: Rect, workspace: Workspace, slotGap: CGFloat) {
    let windowId = window.windowId
    gridFitCheckTasks[windowId]?.cancel()
    gridFitCheckTasks[windowId] = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 20_000_000)
        if Task.isCancelled { return }
        // Skip while the animator is still driving this window.
        if WindowAnimator.shared.isDrivingFrame(windowId) { return }
        guard let actual = try? await window.getAxRect() else { return }
        let widthOver = actual.width - r.width
        let heightOver = actual.height - r.height
        guard widthOver > 20 || heightOver > 20 else { return }
        guard let span = workspace.stackingLayout.placements[windowId] else { return }
        let layout = workspace.stackingLayout
        var minSize = layout.observedMinSizes[windowId] ?? .zero
        if widthOver > 20  { minSize.width  = max(minSize.width,  actual.width)  }
        if heightOver > 20 { minSize.height = max(minSize.height, actual.height) }
        layout.observedMinSizes[windowId] = minSize
        let monRect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let isLandscape = layout.shape.orientation == .landscape
        let used = layout.usedLanes
        let slots = layout.slotCount(in: span.lane0)
        let totalLaneGap = max(0, CGFloat(used.count - 1)) * slotGap
        let totalSlotGap = max(0, CGFloat(slots - 1)) * slotGap
        let usableLanePx = (isLandscape ? monRect.width : monRect.height) - totalLaneGap
        let usableSlotPx = (isLandscape ? monRect.height : monRect.width) - totalSlotGap
        let laneOver = isLandscape ? widthOver : heightOver
        let slotOver = isLandscape ? heightOver : widthOver
        let requiredLanePx = isLandscape ? actual.width : actual.height
        let requiredSlotPx = isLandscape ? actual.height : actual.width
        var changed = false
        if laneOver > 20 {
            // Grow the whole column to fit this window's min width (grow-only,
            // so the column settles at its widest window's min and every
            // window in it fills that width).
            changed = layout.growLaneToFit(
                requiredPx: requiredLanePx, lane: span.lane0,
                totalUsablePx: usableLanePx,
            ) || changed
        }
        if slotOver > 20 {
            changed = layout.growSlotToFit(
                requiredPx: requiredSlotPx, lane: span.lane0, slot: span.slot0,
                totalUsablePx: usableSlotPx,
            ) || changed
        }
        if changed {
            scheduleCancellableCompleteRefreshSession(.ax("grow-to-fit"))
        }
        gridFitCheckTasks[windowId] = nil
    }
}

private struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps

    @MainActor
    init(_ workspace: Workspace) {
        self.workspace = workspace
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext) async throws {
        let workspace = context.workspace
        let windowRect = try await getAxRect() // Probably not idempotent
        let currentMonitor = windowRect?.center.monitorApproximation
        if let currentMonitor, let windowRect, workspace != currentMonitor.activeWorkspace {
            let windowTopLeftCorner = windowRect.topLeftCorner
            let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
            let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

            let workspaceRect = workspace.workspaceMonitor.visibleRect
            var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height

            let windowWidth = windowRect.width
            let windowHeight = windowRect.height
            newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
            newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

            setAxFrame(CGPoint(x: newX, y: newY), nil)
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect = noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitor.visibleRect
            : context.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        setAxFrame(monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        var point = point
        var virtualPoint = virtual.topLeftCorner

        guard let delta = ((orientation == .h ? width : height) - CGFloat(children.sumOfDouble { $0.getWeight(orientation) }))
            .div(children.count) else { return }

        let lastIndex = children.indices.last
        for (i, child) in children.enumerated() {
            child.setWeight(orientation, child.getWeight(orientation) + delta)
            let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
            // Gaps. Consider 4 cases:
            // 1. Multiple children. Layout first child
            // 2. Multiple children. Layout last child
            // 3. Multiple children. Layout child in the middle
            // 4. Single child   let rawGap = gaps.inner.get(orientation).toDouble()
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            try await child.layoutRecursive(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? child.hWeight - gap : width,
                height: orientation == .v ? child.vWeight - gap : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? child.hWeight : width,
                    height: orientation == .v ? child.vWeight : height,
                ),
                context,
            )
            virtualPoint = orientation == .h ? virtualPoint.addingXOffset(child.hWeight) : virtualPoint.addingYOffset(child.vWeight)
            point = orientation == .h ? point.addingXOffset(child.hWeight) : point.addingYOffset(child.vWeight)
        }
    }

    @MainActor
    fileprivate func layoutAccordion(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        guard let mruIndex: Int = mostRecentChild?.ownIndex else { return }
        for (index, child) in children.enumerated() {
            let padding = CGFloat(config.accordionPadding)
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where children.count == 1: (0, 0)
                case 0:                           (0, padding)
                case children.indices.last:       (padding, 0)
                case mruIndex - 1:                (0, 2 * padding)
                case mruIndex + 1:                (2 * padding, 0)
                default:                          (padding, padding)
            }
            switch orientation {
                case .h:
                    try await child.layoutRecursive(
                        point + CGPoint(x: lPadding, y: 0),
                        width: width - rPadding - lPadding,
                        height: height,
                        virtual: virtual,
                        context,
                    )
                case .v:
                    try await child.layoutRecursive(
                        point + CGPoint(x: 0, y: lPadding),
                        width: width,
                        height: height - lPadding - rPadding,
                        virtual: virtual,
                        context,
                    )
            }
        }
    }
}
