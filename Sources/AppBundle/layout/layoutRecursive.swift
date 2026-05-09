import AppKit

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws {
        // mur — phase 1.3. When the experimental grid is enabled AND it
        // owns at least one window, dispatch to the grid path. Otherwise
        // fall through to the existing tree-based layout. This means the
        // tree continues to drive layout for any pre-existing windows
        // that haven't been migrated into the grid yet.
        if config.experimentalGridLayout && !gridLayout.isEmpty {
            try await layoutWorkspaceWithGrid()
            return
        }
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, LayoutContext(self))
    }

    /// mur — phase 1.3 grid-based layout dispatch.
    ///
    /// Walks `gridLayout.zOrder` back→front and `setAxFrame`s each tiled
    /// window to the rect resolved from its `TileSpan`. Floating windows
    /// (direct Window children of this Workspace) are then laid out by
    /// the existing path. The tree (`rootTilingContainer`) is dormant
    /// when this method runs.
    ///
    /// Z-order: setAxFrame doesn't control front-to-back ordering on its
    /// own; that's a focus/raise concern handled when a window is
    /// promoted in `gridLayout`. This function only places geometry.
    @MainActor
    fileprivate func layoutWorkspaceWithGrid() async throws {
        let context = LayoutContext(self)
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // Reshape if monitor orientation has changed since last layout.
        let mon = rect
        let nowOrientation = LayoutOrientation.forMonitor(width: mon.width, height: mon.height)
        if nowOrientation != gridLayout.shape.orientation {
            _ = gridLayout.reshape(to: LayoutShape(orientation: nowOrientation, lanes: gridLayout.shape.lanes))
        }
        // Single-axis inner gap for now (slot axis). Lane-axis gap is
        // a refinement for a later commit; in the meantime, slots and
        // lanes share the same gap for visual consistency.
        let slotGap = CGFloat(context.resolvedGaps.inner.get(
            gridLayout.shape.orientation == .landscape ? .v : .h
        ))

        for windowId in gridLayout.zOrder {
            guard let window = Window.get(byId: windowId) else { continue }
            if window.windowId == currentlyManipulatedWithMouseWindowId { continue }
            guard let r = gridLayout.resolveRect(for: windowId, in: rect, innerGap: slotGap) else { continue }
            window.lastAppliedLayoutPhysicalRect = r
            window.lastAppliedLayoutVirtualRect = r
            window.setAxFrame(r.topLeftCorner, r.size)

            // mur — auto-float non-resizable windows. Once per window:
            // wait briefly for the resize to settle, then compare the
            // actual rect against what we asked for. If both dims differ
            // by more than 150px, the app has a fixed window size we
            // can't tile — float it. Threshold accommodates min-size
            // constraints that narrow ONE dimension only.
            if !gridLayout.verifiedResizableWindows.contains(windowId)
                && !gridLayout.nonResizableWindows.contains(windowId)
            {
                let workspace = self
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard let actual = try? await window.getAxRect() else { return }
                    let widthDiff = abs(actual.width - r.width)
                    let heightDiff = abs(actual.height - r.height)
                    if widthDiff > 150 && heightDiff > 150 {
                        workspace.gridLayout.nonResizableWindows.insert(windowId)
                        // Remember the app bundle so future windows of
                        // the same app skip grid registration entirely
                        // and open as floating.
                        let appId = window.app.rawAppBundleId ?? ""
                        if !appId.isEmpty { knownNonResizableAppIds.insert(appId) }
                        _ = workspace.gridLayout.remove(windowId)
                        window.bindAsFloatingWindow(to: workspace)
                        let monRect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
                        let cx = monRect.topLeftX + (monRect.width - actual.width) / 2
                        let cy = monRect.topLeftY + (monRect.height - actual.height) / 2
                        window.setAxFrame(CGPoint(x: cx, y: cy), actual.size)
                    } else {
                        workspace.gridLayout.verifiedResizableWindows.insert(windowId)
                    }
                }
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
