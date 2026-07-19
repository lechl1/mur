import AppKit
import Common
import Foundation

/// `stacking-move` fallback when the focused window has no in-workspace
/// target in the requested direction (alone at a lane edge, or no
/// slot-mate at a slot edge). Direction-based, not orientation-based:
///   - up/down  → move the window to the prev/next workspace on the
///                same monitor and follow focus. Always wraps within
///                the monitor's workspace list.
///   - left/right → move the window to the active workspace of the
///                  monitor in that direction. If there's no monitor
///                  there, return false so the caller can fall back to
///                  the existing edge-shrink behaviour.
/// Returns true if the window was relocated, false if the caller should
/// run its in-workspace fallback (the shrink).
@MainActor
private func crossWorkspaceOrMonitorFallback(
    direction: CardinalDirection,
    window: Window,
    sourceWorkspace: Workspace,
    target: LiveFocus,
    io: CmdIo,
) -> Bool {
    let dest: Workspace?
    switch direction {
        case .up, .down:
            dest = getNextPrevWorkspace(
                current: sourceWorkspace,
                isNext: direction == .down,
                wrapAround: true,
                stdin: nil,
                target: target,
            )
        case .left, .right:
            switch MonitorTarget.direction(direction).resolve(
                sourceWorkspace.workspaceMonitor, wrapAround: false,
            ) {
                case .success(let monitor): dest = monitor.activeWorkspace
                case .failure:               dest = nil
            }
    }
    guard let dest, dest != sourceWorkspace else { return false }
    let sourceRect = window.lastAppliedLayoutPhysicalRect
    _ = sourceWorkspace.stackingLayout.remove(window.windowId)
    _ = moveWindowToWorkspace(
        window, dest, io,
        focusFollowsWindow: true, failIfNoop: false,
    )
    // Best-effort: insert the window into the destination grid at the cell
    // it "enters" — the edge opposite the move direction, aligned to where
    // it exited — rather than the generic placement heuristic.
    insertMovedWindowPositionally(
        window, into: dest, direction: direction,
        sourceRect: sourceRect, sourceWorkspace: sourceWorkspace,
    )
    if let newSpan = dest.stackingLayout.placements[window.windowId] {
        StackingHud.shared.update(layout: dest.stackingLayout, span: newSpan)
    }
    return true
}

/// Insert `window` into `dest`'s grid at the cell it enters when moved in
/// `direction`: the edge opposite the move (right → dest's left edge,
/// down → dest's top edge, …), aligned to where the window exited the
/// source (mapped proportionally across monitors of different sizes). It
/// merges as a new row of the entered column, inserted between that
/// column's windows at the matching position — so a cross-workspace /
/// cross-monitor move lands where you'd expect, like an in-workspace merge.
@MainActor
private func insertMovedWindowPositionally(
    _ window: Window,
    into dest: Workspace,
    direction: CardinalDirection,
    sourceRect: Rect?,
    sourceWorkspace: Workspace,
) {
    let layout = dest.stackingLayout
    let destAvail = dest.workspaceMonitor.visibleRectPaddedByOuterGaps
    let sg = CGFloat(ResolvedGaps(gaps: config.gaps, monitor: dest.workspaceMonitor)
        .inner.get(layout.shape.orientation == .landscape ? .v : .h))
    if layout.isEmpty {
        layout.place(window.windowId, at: .soleSlot(lane: 0))
        return
    }
    // Proportional position of where the window exited the source.
    let srcAvail = sourceWorkspace.workspaceMonitor.visibleRectPaddedByOuterGaps
    let srcCenter = sourceRect?.center ?? srcAvail.center
    let fx = srcAvail.width > 0 ? (srcCenter.x - srcAvail.topLeftX) / srcAvail.width : 0.5
    let fy = srcAvail.height > 0 ? (srcCenter.y - srcAvail.topLeftY) / srcAvail.height : 0.5
    let entry: CGPoint
    switch direction {
        case .right: entry = CGPoint(x: destAvail.topLeftX + 1,                       y: destAvail.topLeftY + fy * destAvail.height)
        case .left:  entry = CGPoint(x: destAvail.topLeftX + destAvail.width - 1,      y: destAvail.topLeftY + fy * destAvail.height)
        case .down:  entry = CGPoint(x: destAvail.topLeftX + fx * destAvail.width,     y: destAvail.topLeftY + 1)
        case .up:    entry = CGPoint(x: destAvail.topLeftX + fx * destAvail.width,     y: destAvail.topLeftY + destAvail.height - 1)
    }
    guard let cell = layout.cellAt(point: entry, in: destAvail, innerGap: sg) else {
        layout.place(window.windowId, at: .soleSlot(lane: 0))
        return
    }
    let insertAt = layout.insertionSlot(in: cell.lane, at: entry, available: destAvail, innerGap: sg)
    layout.insertSlot(in: cell.lane, at: insertAt)
    layout.place(window.windowId, at: .single(lane: cell.lane, slot: insertAt))
}

/// Per-window alternation state for `stacking-move` on the lane axis.
/// Same window + same direction → toggle between MERGE-AS-ROW (move into
/// the neighbour column as a new row) and ADD-NEW-TILE (insert a new
/// column between source and neighbour). Direction change OR window
/// change resets the counter, and the first action of a fresh gesture is
/// MERGE-AS-ROW — moving into an adjacent column inserts a row there, it
/// never stacks focused on top of an existing window.
@MainActor private var stackingMoveGesture: StackingMoveGesture? = nil

@MainActor
private struct StackingMoveGesture {
    let windowId: WindowId
    let direction: CardinalDirection
    /// What the NEXT same-direction press should do.
    let nextIsOverlap: Bool
}

/// `mur stacking-move <left|down|up|right>` — move the focused window in
/// the given cardinal direction by swapping with its neighbour.
///
///   - landscape: left/right swap whole columns; up/down swap two rows
///     within the focused lane.
///   - portrait: up/down swap whole rows (lane axis flipped); left/right
///     swap two columns within the focused row.
///
/// Compared to `stacking-resize` (the bloom resize), `stacking-move` is a true
/// move: it carries every other window in the swapped column/row along
/// for the ride and preserves the lane / slot weights of each side.
struct StackingMoveCommand: Command {
    let args: StackingMoveCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard config.experimentalStackingLayout else {
            io.err("stacking-move requires `experimental-stacking-layout = true` in mur.toml")
            return .fail
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            io.err("stacking-move needs a focused window or --window-id <id>")
            return .fail
        }
        let workspace = target.workspace
        let layout = workspace.stackingLayout
        // Floating window → register it into the grid on first
        // keybinding press; subsequent presses run the move as usual.
        // Same affordance as `stacking-resize` so the move keybinding can
        // also be used to "tile" a floating window in one keystroke.
        if layout.placements[window.windowId] == nil {
            let focusedLane = focus.windowOrNil
                .flatMap { layout.placements[$0.windowId]?.lane0 }
            let span = layout.placementForNewWindow(focusedLane: focusedLane)
            layout.place(window.windowId, at: span)
            StackingHud.shared.update(layout: layout, span: span)
            // Reset the alternation so the next press starts a fresh
            // OVERLAP-first gesture from the new tile.
            stackingMoveGesture = nil
            Task { @MainActor in
                let appId = window.app.rawAppBundleId ?? ""
                let title = (try? await window.title) ?? ""
                windowMemory.remember(appId: appId, title: title, workspace: workspace.name, shape: layout.shape, span: span)
                windowMemory.save()
            }
            return .succ
        }
        guard let current = layout.placements[window.windowId] else {
            io.err("window \(window.windowId) is not in the grid (use stacking-place to add it)")
            return .fail
        }

        let shape = layout.shape
        let isLaneAxis: Bool
        let signum: Int
        switch (shape.orientation, args.direction.val) {
            case (.landscape, .left):  (isLaneAxis, signum) = (true,  -1)
            case (.landscape, .right): (isLaneAxis, signum) = (true,  +1)
            case (.landscape, .up):    (isLaneAxis, signum) = (false, -1)
            case (.landscape, .down):  (isLaneAxis, signum) = (false, +1)
            case (.portrait,  .up):    (isLaneAxis, signum) = (true,  -1)
            case (.portrait,  .down):  (isLaneAxis, signum) = (true,  +1)
            case (.portrait,  .left):  (isLaneAxis, signum) = (false, -1)
            case (.portrait,  .right): (isLaneAxis, signum) = (false, +1)
        }

        if isLaneAxis {
            // Deterministic lane-axis move (no alternation), keyed on how
            // many windows share the source column:
            //   - MORE THAN ONE window → EXTRACT the focused window into a
            //     brand-new column in the press direction (works at an edge
            //     too). The column-mates stay put.
            //   - exactly ONE window → MERGE it into the adjacent column as
            //     a new row, emptying the source column. With no adjacent
            //     column it spills to the next workspace / monitor.
            stackingMoveGesture = nil // lane moves are not a stateful gesture

            let myLane = signum > 0 ? current.lane1 : current.lane0
            let used = layout.usedLanes
            guard let visIdx = used.firstIndex(of: myLane) else { return .succ }
            let neighborVisIdx = signum > 0 ? visIdx + 1 : visIdx - 1
            let hasLaneMates = layout.windows(in: myLane).count >= 2

            if hasLaneMates {
                // >1 window in the source column → extract into a new column.
                let insertIdx = signum > 0 ? myLane + 1 : myLane
                layout.insertLane(at: insertIdx)
                layout.place(window.windowId, at: TileSpan(
                    lane0: insertIdx, lane1: insertIdx, slot0: 0, slot1: 0,
                ))
            } else if neighborVisIdx >= 0 && neighborVisIdx < used.count {
                // Lone window + an adjacent column → merge as a new row,
                // inserted at the slot matching the window's current
                // position (above/below the neighbour's rows). It does NOT
                // share a cell with (stack on top of) an existing window.
                let targetLane = used[neighborVisIdx]
                let available = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
                let resolved = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
                let sg = CGFloat(resolved.inner.get(
                    layout.shape.orientation == .landscape ? .v : .h,
                ))
                let focusedRect = window.lastAppliedLayoutPhysicalRect
                    ?? layout.resolveRect(for: window.windowId, in: available, innerGap: sg)
                let center = focusedRect?.center ?? available.center
                let insertAt = layout.insertionSlot(
                    in: targetLane, at: center, available: available, innerGap: sg,
                )
                layout.insertSlot(in: targetLane, at: insertAt)
                layout.place(window.windowId, at: TileSpan(
                    lane0: targetLane, lane1: targetLane,
                    slot0: insertAt, slot1: insertAt,
                ))
            } else {
                // Lone window at the edge, no adjacent column → spill to the
                // next workspace (up/down) / monitor (left/right). If there's
                // no monitor in that direction, do nothing — no edge resize.
                _ = crossWorkspaceOrMonitorFallback(
                    direction: args.direction.val,
                    window: window,
                    sourceWorkspace: workspace,
                    target: target,
                    io: io,
                )
            }
        } else {
            // Slot axis (top/bottom in landscape, left/right in portrait).
            // Same alternation as the lane axis:
            //   - slot-mates exist (focused shares the cell) → EXTRACT
            //     focused into a fresh slot so they un-overlap.
            //   - neighbour slot exists → alternate per same-direction
            //     press: OVERLAP (focused moves to neighbour's slot,
            //     sharing the cell) then ADD-NEW-TILE (insert new slot
            //     between source and neighbour).
            //   - edge, no slot-mates → shrink the row.
            let myLane = current.lane0
            let mySlot = signum > 0 ? current.slot1 : current.slot0
            let slots = layout.slotCount(in: myLane)
            let neighborSlot = signum > 0 ? mySlot + 1 : mySlot - 1
            let slotMates = layout.placements.contains { wid, span in
                wid != window.windowId
                    && span.lane0 <= myLane && myLane <= span.lane1
                    && span.slot0 <= mySlot && mySlot <= span.slot1
            }
            if slotMates {
                let insertAt = signum > 0 ? mySlot + 1 : mySlot
                layout.insertSlot(in: myLane, at: insertAt)
                layout.place(window.windowId, at: TileSpan(
                    lane0: myLane, lane1: myLane,
                    slot0: insertAt, slot1: insertAt,
                ))
            } else if neighborSlot >= 0 && neighborSlot < slots {
                let dir = args.direction.val
                let slotIsOverlap: Bool
                if let g = stackingMoveGesture, g.windowId == window.windowId, g.direction == dir {
                    slotIsOverlap = g.nextIsOverlap
                } else {
                    slotIsOverlap = true
                }
                stackingMoveGesture = StackingMoveGesture(
                    windowId: window.windowId, direction: dir, nextIsOverlap: !slotIsOverlap,
                )
                if slotIsOverlap {
                    // OVERLAP with the adjacent slot's window: place
                    // focused at the same slot index — they share the
                    // cell and z-order picks the front.
                    layout.place(window.windowId, at: TileSpan(
                        lane0: myLane, lane1: myLane,
                        slot0: neighborSlot, slot1: neighborSlot,
                    ))
                } else {
                    // ADD-NEW-TILE: insert a fresh slot between source
                    // and neighbour; focused moves into it alone.
                    let insertAt = signum > 0 ? mySlot + 1 : mySlot
                    layout.insertSlot(in: myLane, at: insertAt)
                    layout.place(window.windowId, at: TileSpan(
                        lane0: myLane, lane1: myLane,
                        slot0: insertAt, slot1: insertAt,
                    ))
                }
            } else {
                // Edge of lane, no slot-mate, no neighbour slot → no
                // in-workspace target. up/down → next/prev workspace;
                // left/right → next monitor in that direction; otherwise
                // fall back to shrink.
                if !crossWorkspaceOrMonitorFallback(
                    direction: args.direction.val,
                    window: window,
                    sourceWorkspace: workspace,
                    target: target,
                    io: io,
                ) {
                    StackingResize.resizeSlot(layout: layout, lane: myLane, slot: mySlot, signum: -1)
                }
            }
        }

        // Re-fetch the focused window's new placement for HUD + memory.
        if let newSpan = layout.placements[window.windowId] {
            StackingHud.shared.update(layout: layout, span: newSpan)
            Task { @MainActor in
                let appId = window.app.rawAppBundleId ?? ""
                let title = (try? await window.title) ?? ""
                windowMemory.remember(appId: appId, title: title, workspace: workspace.name, shape: shape, span: newSpan)
                windowMemory.save()
            }
        }
        return .succ
    }
}
