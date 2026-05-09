import AppKit
import Common
import Foundation

/// Per-window alternation state for `grid-swap` on the lane axis.
/// Same window + same direction → toggle between OVERLAP (merge into
/// neighbour as a new row) and ADD-NEW-TILE (insert a new column
/// between source and neighbour). Direction change OR window change
/// resets the counter, and the first action of a fresh gesture is
/// OVERLAP.
@MainActor private var gridSwapGesture: GridSwapGesture? = nil

@MainActor
private struct GridSwapGesture {
    let windowId: WindowId
    let direction: CardinalDirection
    /// What the NEXT same-direction press should do.
    let nextIsOverlap: Bool
}

/// `mur grid-swap <left|down|up|right>` — swap the focused window's
/// column / row with the neighbour in the given cardinal direction.
///
///   - landscape: left/right swap whole columns; up/down swap two rows
///     within the focused lane.
///   - portrait: up/down swap whole rows (lane axis flipped); left/right
///     swap two columns within the focused row.
///
/// Compared to `grid-move` (the bloom resize), `grid-swap` is a true
/// move: it carries every other window in the swapped column/row along
/// for the ride and preserves the lane / slot weights of each side.
struct GridSwapCommand: Command {
    let args: GridSwapCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard config.experimentalGridLayout else {
            io.err("grid-swap requires `experimental-grid-layout = true` in mur.toml")
            return .fail
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            io.err("grid-swap needs a focused window or --window-id <id>")
            return .fail
        }
        let workspace = target.workspace
        let layout = workspace.gridLayout
        // Floating window → register it into the grid on first
        // keybinding press; subsequent presses run the move as usual.
        // Same affordance as `grid-move` so ctrl-alt-arrow can also be
        // used to "tile" a floating window in one keystroke.
        if layout.placements[window.windowId] == nil {
            let focusedLane = focus.windowOrNil
                .flatMap { layout.placements[$0.windowId]?.lane0 }
            let span = layout.placementForNewWindow(focusedLane: focusedLane)
            layout.place(window.windowId, at: span)
            GridHud.shared.update(layout: layout, span: span)
            // Reset the alternation so the next ctrl-alt-arrow starts
            // a fresh OVERLAP-first gesture from the new tile.
            gridSwapGesture = nil
            Task { @MainActor in
                let appId = window.app.rawAppBundleId ?? ""
                let title = (try? await window.title) ?? ""
                windowMemory.remember(appId: appId, title: title, shape: layout.shape, span: span)
                windowMemory.save()
            }
            return .succ
        }
        guard let current = layout.placements[window.windowId] else {
            io.err("window \(window.windowId) is not in the grid (use grid-place to add it)")
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
            // Lane-axis press alternates between OVERLAP and
            // ADD-NEW-TILE on consecutive same-direction presses.
            // Direction change OR window change resets the counter,
            // and the first action of a fresh gesture is OVERLAP.
            let dir = args.direction.val
            let isOverlap: Bool
            if let g = gridSwapGesture, g.windowId == window.windowId, g.direction == dir {
                isOverlap = g.nextIsOverlap
            } else {
                isOverlap = true
            }
            gridSwapGesture = GridSwapGesture(
                windowId: window.windowId, direction: dir, nextIsOverlap: !isOverlap,
            )

            let myLane = signum > 0 ? current.lane1 : current.lane0
            let used = layout.usedLanes
            guard let visIdx = used.firstIndex(of: myLane) else { return .succ }
            let neighborVisIdx = signum > 0 ? visIdx + 1 : visIdx - 1
            let hasLaneMates = layout.windows(in: myLane).count >= 2
            if neighborVisIdx >= 0 && neighborVisIdx < used.count {
                if isOverlap {
                    // OVERLAP: pick the existing window in the adjacent
                    // column whose centre is closest to focused's
                    // current centre (position-aware), and place focused
                    // at that same slot — the two windows share the
                    // cell and visually overlap (z-order decides front).
                    let targetLane = used[neighborVisIdx]
                    let available = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
                    let resolved = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
                    let sg = CGFloat(resolved.inner.get(
                        layout.shape.orientation == .landscape ? .v : .h,
                    ))
                    let focusedRect = window.lastAppliedLayoutPhysicalRect
                        ?? layout.resolveRect(for: window.windowId, in: available, innerGap: sg)
                    let center = focusedRect?.center ?? available.center
                    let targetSlot = layout.nearestOccupiedSlot(
                        in: targetLane, to: center, available: available, innerGap: sg,
                    ) ?? 0
                    layout.place(window.windowId, at: TileSpan(
                        lane0: targetLane, lane1: targetLane,
                        slot0: targetSlot, slot1: targetSlot,
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
                // Outward press at edge, alone → shrink.
                GridMove.resizeLane(layout: layout, lane: myLane, signum: -1)
            }
        } else {
            // Slot axis (top/bottom in landscape, left/right in portrait).
            //   - slot-mates exist (focused shares the cell with another
            //     window) → EXTRACT focused into a fresh slot in the
            //     press direction so the two windows un-overlap.
            //   - neighbour slot exists → swap.
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
                layout.swapSlots(in: myLane, mySlot, neighborSlot)
            } else {
                GridMove.resizeSlot(layout: layout, lane: myLane, slot: mySlot, signum: -1)
            }
        }

        // Re-fetch the focused window's new placement for HUD + memory.
        if let newSpan = layout.placements[window.windowId] {
            GridHud.shared.update(layout: layout, span: newSpan)
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
