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
    _ = sourceWorkspace.stackingLayout.remove(window.windowId)
    _ = moveWindowToWorkspace(
        window, dest, io,
        focusFollowsWindow: true, failIfNoop: false,
    )
    tryRegisterInStackingLayout(window)
    if let newSpan = dest.stackingLayout.placements[window.windowId] {
        StackingHud.shared.update(layout: dest.stackingLayout, span: newSpan)
    }
    return true
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
                windowMemory.remember(appId: appId, title: title, shape: layout.shape, span: span)
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
            // Lane-axis press alternates between MERGE-AS-ROW and
            // ADD-NEW-TILE on consecutive same-direction presses.
            // Direction change OR window change resets the counter,
            // and the first action of a fresh gesture is MERGE-AS-ROW.
            let dir = args.direction.val
            let isOverlap: Bool
            if let g = stackingMoveGesture, g.windowId == window.windowId, g.direction == dir {
                isOverlap = g.nextIsOverlap
            } else {
                isOverlap = true
            }
            stackingMoveGesture = StackingMoveGesture(
                windowId: window.windowId, direction: dir, nextIsOverlap: !isOverlap,
            )

            let myLane = signum > 0 ? current.lane1 : current.lane0
            let used = layout.usedLanes
            guard let visIdx = used.firstIndex(of: myLane) else { return .succ }
            let neighborVisIdx = signum > 0 ? visIdx + 1 : visIdx - 1
            let hasLaneMates = layout.windows(in: myLane).count >= 2
            if neighborVisIdx >= 0 && neighborVisIdx < used.count {
                if isOverlap {
                    // MERGE-AS-ROW: move focused into the adjacent column
                    // as a NEW ROW. The insertion slot is chosen from
                    // focused's current position along the slot axis, so
                    // it lands above/below the neighbour's rows to match
                    // where the user aimed. It does NOT share a cell with
                    // (stack on top of) an existing window.
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
                    // ADD-NEW-TILE: insert a fresh lane between source
                    // and neighbour; focused moves into it alone.
                    let insertIdx = signum > 0 ? myLane + 1 : myLane
                    layout.insertLane(at: insertIdx)
                    layout.place(window.windowId, at: TileSpan(
                        lane0: insertIdx, lane1: insertIdx,
                        slot0: 0, slot1: 0,
                    ))
                }
            } else if hasLaneMates {
                // Outward press at edge while overlapping → new column.
                if signum > 0 {
                    let nextEmpty = (used.last ?? -1) + 1
                    let target = nextEmpty < layout.shape.lanes ? nextEmpty : layout.appendLane()
                    layout.place(window.windowId, at: TileSpan(
                        lane0: target, lane1: target,
                        slot0: 0, slot1: 0,
                    ))
                } else {
                    layout.insertLaneAtFront()
                    layout.place(window.windowId, at: TileSpan(
                        lane0: 0, lane1: 0,
                        slot0: 0, slot1: 0,
                    ))
                }
            } else {
                // Outward press at edge, alone → no in-workspace target.
                // up/down → next/prev workspace; left/right → next monitor
                // in that direction; otherwise fall back to shrink.
                if !crossWorkspaceOrMonitorFallback(
                    direction: args.direction.val,
                    window: window,
                    sourceWorkspace: workspace,
                    target: target,
                    io: io,
                ) {
                    StackingResize.resizeLane(layout: layout, lane: myLane, signum: -1)
                }
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
                windowMemory.remember(appId: appId, title: title, shape: shape, span: newSpan)
                windowMemory.save()
            }
        }
        return .succ
    }
}
