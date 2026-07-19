import AppKit
import Common
import Foundation

/// `mur stacking-focus-dir <left|down|up|right>` — focus the spatial
/// neighbor of the currently-focused window inside the grid layout.
struct StackingFocusDirCommand: Command {
    let args: StackingFocusDirCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard config.experimentalStackingLayout else {
            io.err("stacking-focus-dir requires `experimental-stacking-layout = true` in mur.toml")
            return .fail
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            io.err("stacking-focus-dir needs a focused window")
            return .fail
        }
        let workspace = target.workspace
        let layout = workspace.stackingLayout
        guard let current = layout.placements[window.windowId] else {
            io.err("focused window \(window.windowId) is not in the grid")
            return .fail
        }

        // Translate (orientation, direction) → (axis, signum).
        // axis = .lane → search across lanes; .slot → search within current lane.
        // signum = +1 → looking for higher index; -1 → lower.
        enum Axis { case lane, slot }
        let axis: Axis
        let signum: Int
        switch (layout.shape.orientation, args.direction.val) {
            case (.landscape, .left):  (axis, signum) = (.lane, -1)
            case (.landscape, .right): (axis, signum) = (.lane, +1)
            case (.landscape, .up):    (axis, signum) = (.slot, -1)
            case (.landscape, .down):  (axis, signum) = (.slot, +1)
            case (.portrait,  .left):  (axis, signum) = (.slot, -1)
            case (.portrait,  .right): (axis, signum) = (.slot, +1)
            case (.portrait,  .up):    (axis, signum) = (.lane, -1)
            case (.portrait,  .down):  (axis, signum) = (.lane, +1)
        }

        // Distance from the current span to a candidate span in the chosen
        // axis + signum. Returns nil if the candidate isn't in the half-plane.
        // For lane-axis search we measure between the *outer* lanes of each
        // span: from `current.lane1` to `span.lane0` going right (signum>0)
        // and from `current.lane0` to `span.lane1` going left.
        // For slot-axis search the candidate must overlap the current span
        // along the lane axis.
        func distance(to span: TileSpan) -> Int? {
            switch axis {
                case .lane:
                    let delta = signum > 0
                        ? span.lane0 - current.lane1
                        : current.lane0 - span.lane1
                    return delta > 0 ? delta : nil
                case .slot:
                    let laneOverlap = max(span.lane0, current.lane0) <= min(span.lane1, current.lane1)
                    if !laneOverlap { return nil }
                    let delta = signum > 0
                        ? span.slot0 - current.slot1
                        : current.slot0 - span.slot1
                    return delta > 0 ? delta : nil
            }
        }

        // Collect candidates with distances; pick smallest distance, then
        // highest zOrder index (topmost) on ties.
        struct Candidate { let id: WindowId; let dist: Int; let zIdx: Int }
        var candidates: [Candidate] = []
        for (wid, span) in layout.placements where wid != window.windowId {
            guard let d = distance(to: span) else { continue }
            let z = layout.zOrder.firstIndex(of: wid) ?? -1
            candidates.append(Candidate(id: wid, dist: d, zIdx: z))
        }
        if let best = candidates.min(by: { a, b in
            a.dist != b.dist ? a.dist < b.dist : a.zIdx > b.zIdx
        }) {
            guard let nextWindow = Window.get(byId: best.id) else { return .fail }
            nextWindow.nativeFocus()
            layout.promote(best.id)
            return .succ
        }

        // No legal target in the requested direction → the focus leaves
        // the screen on that edge. Cross to the adjacent workspace
        // (up = prev, down = next; wraps) or monitor (left/right) and
        // focus the closest matching window there — mirrors the
        // cross-edge fallback in `stacking-move`. Returns nil only when
        // there's no adjacent workspace/monitor, in which case we fall
        // through to in-cell sibling cycling below.
        if let code = crossEdgeFocus(
            direction: args.direction.val,
            sourceWindow: window,
            sourceWorkspace: workspace,
            target: target,
        ) {
            return code
        }

        // No legal target in the requested direction. Cycle through
        // windows that share the focused tile instead — i.e. windows
        // whose span overlaps the focused window's span. zOrder is
        // ordered oldest → most-recent, so picking the highest zIdx
        // among the siblings gives Cmd-Tab-style cycling through
        // overlapping windows in the same cell.
        struct Sibling { let id: WindowId; let zIdx: Int }
        var siblings: [Sibling] = []
        for (wid, span) in layout.placements where wid != window.windowId {
            let laneOverlap = max(span.lane0, current.lane0) <= min(span.lane1, current.lane1)
            let slotOverlap = max(span.slot0, current.slot0) <= min(span.slot1, current.slot1)
            if laneOverlap && slotOverlap {
                siblings.append(Sibling(id: wid, zIdx: layout.zOrder.firstIndex(of: wid) ?? -1))
            }
        }
        guard let topmost = siblings.max(by: { $0.zIdx < $1.zIdx }) else {
            io.err("no grid window in direction \(args.direction.val.rawValue) from focused window")
            return .fail
        }
        guard let nextWindow = Window.get(byId: topmost.id) else { return .fail }
        nextWindow.nativeFocus()
        layout.promote(topmost.id)
        return .succ
    }
}

// MARK: - Cross-workspace / monitor edge focus

/// Cross the workspace/monitor edge in `direction` and focus the closest
/// matching window in the destination:
///   - up/down    → previous/next workspace on the same monitor (wraps).
///   - left/right → active workspace of the monitor in that direction.
/// The landed-on window is the one nearest where the focus "exited" —
/// entering from the opposite edge, aligned to the source window's
/// position along the perpendicular axis. An empty destination just
/// switches focus to that workspace. Returns nil when there's no
/// adjacent workspace/monitor (single workspace, or outermost monitor).
@MainActor
private func crossEdgeFocus(
    direction: CardinalDirection,
    sourceWindow: Window,
    sourceWorkspace: Workspace,
    target: LiveFocus,
) -> BinaryExitCode? {
    let dest: Workspace?
    switch direction {
        case .up, .down:
            // Down → next, up → previous workspace on the same monitor,
            // INCLUDING empty ones, so the focus can leave the screen onto a
            // workspace that currently has no windows and still switch there.
            dest = adjacentWorkspaceIncludingEmpty(from: sourceWorkspace, isNext: direction == .down)
        case .left, .right:
            switch MonitorTarget.direction(direction).resolve(
                sourceWorkspace.workspaceMonitor, wrapAround: false,
            ) {
                case .success(let monitor): dest = monitor.activeWorkspace
                case .failure:               dest = nil
            }
    }
    guard let dest, dest != sourceWorkspace else { return nil }

    if let entryId = entryWindow(
        in: dest, movingIn: direction,
        sourceWindow: sourceWindow, sourceWorkspace: sourceWorkspace,
    ), let entryWin = Window.get(byId: entryId) {
        _ = entryWin.focusWindow()
        entryWin.nativeFocus()
        dest.stackingLayout.promote(entryId)
    } else {
        // Empty destination → still switch to it (blank workspace).
        _ = dest.focusWorkspace()
    }
    return .succ
}

/// Next (`isNext`) / previous workspace on `current`'s monitor, INCLUDING
/// empty ones. Unlike a bare `Workspace.all` walk, this materialises every
/// declared (persistent) workspace so an empty workspace between two used
/// ones is still navigable and the focus can switch onto it. Wraps around;
/// returns nil only when the monitor has a single navigable workspace.
@MainActor
private func adjacentWorkspaceIncludingEmpty(from current: Workspace, isNext: Bool) -> Workspace? {
    let monitorCorner = current.workspaceMonitor.rect.topLeftCorner
    var byName: [String: Workspace] = [current.name: current]
    for name in config.persistentWorkspaces { byName[name] = Workspace.get(byName: name) }
    for ws in Workspace.all { byName[ws.name] = ws }
    let ordered = byName.values
        .filter { $0.workspaceMonitor.rect.topLeftCorner == monitorCorner }
        .sorted()
    guard ordered.count > 1, let idx = ordered.firstIndex(of: current) else { return nil }
    let n = ((isNext ? idx + 1 : idx - 1) % ordered.count + ordered.count) % ordered.count
    let dest = ordered[n]
    return dest == current ? nil : dest
}

/// Inner gap (slot axis) for a workspace's stacking layout.
@MainActor
private func slotGap(of workspace: Workspace) -> CGFloat {
    let layout = workspace.stackingLayout
    return CGFloat(ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
        .inner.get(layout.shape.orientation == .landscape ? .v : .h))
}

/// Pick the destination window to land on when crossing into `dest` from
/// the edge opposite `direction`. Primary key: alignment with the source
/// window along the perpendicular axis (proportional, so it works across
/// monitors of different sizes). Tie-break: proximity to the entry edge.
@MainActor
private func entryWindow(
    in dest: Workspace,
    movingIn direction: CardinalDirection,
    sourceWindow: Window,
    sourceWorkspace: Workspace,
) -> WindowId? {
    let layout = dest.stackingLayout
    if layout.isEmpty { return nil }
    let destAvail = dest.workspaceMonitor.visibleRectPaddedByOuterGaps
    let srcAvail = sourceWorkspace.workspaceMonitor.visibleRectPaddedByOuterGaps
    let destGap = slotGap(of: dest)

    // Source window's screen rect (in the source workspace).
    let srcRect = sourceWindow.lastAppliedLayoutPhysicalRect
        ?? sourceWorkspace.stackingLayout.resolveRect(
            for: sourceWindow.windowId, in: srcAvail, innerGap: slotGap(of: sourceWorkspace),
        )
    let srcCenter = srcRect?.center ?? srcAvail.center

    let vertical = direction == .up || direction == .down
    // Perpendicular fraction of the source position (0…1).
    let srcPerpFrac: CGFloat = vertical
        ? (srcAvail.width  > 0 ? (srcCenter.x - srcAvail.topLeftX) / srcAvail.width  : 0.5)
        : (srcAvail.height > 0 ? (srcCenter.y - srcAvail.topLeftY) / srcAvail.height : 0.5)

    var best: (id: WindowId, perp: CGFloat, edge: CGFloat)? = nil
    for wid in layout.placements.keys {
        guard let r = layout.resolveRect(for: wid, in: destAvail, innerGap: destGap) else { continue }
        let c = r.center
        let destPerpFrac: CGFloat = vertical
            ? (destAvail.width  > 0 ? (c.x - destAvail.topLeftX) / destAvail.width  : 0.5)
            : (destAvail.height > 0 ? (c.y - destAvail.topLeftY) / destAvail.height : 0.5)
        let perpDist = abs(srcPerpFrac - destPerpFrac)
        let edgeDist: CGFloat
        switch direction {
            case .down:  edgeDist = r.topLeftY - destAvail.topLeftY                                  // near top
            case .up:    edgeDist = (destAvail.topLeftY + destAvail.height) - (r.topLeftY + r.height) // near bottom
            case .right: edgeDist = r.topLeftX - destAvail.topLeftX                                  // near left
            case .left:  edgeDist = (destAvail.topLeftX + destAvail.width) - (r.topLeftX + r.width)   // near right
        }
        if let b = best {
            if perpDist < b.perp - 0.001 || (abs(perpDist - b.perp) <= 0.001 && edgeDist < b.edge) {
                best = (wid, perpDist, edgeDist)
            }
        } else {
            best = (wid, perpDist, edgeDist)
        }
    }
    return best?.id
}
