import AppKit
import Common
import Foundation

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
            // Merge into neighbour lane as a new bottom slot ("move
            // through" semantics — not swap). Source lane is left for
            // `compactGaps()` in `place()` to rebalance / remove.
            let myLane = signum > 0 ? current.lane1 : current.lane0
            let used = layout.usedLanes
            guard let visIdx = used.firstIndex(of: myLane) else { return .succ }
            let neighborVisIdx = signum > 0 ? visIdx + 1 : visIdx - 1
            if neighborVisIdx >= 0 && neighborVisIdx < used.count {
                let targetLane = used[neighborVisIdx]
                // Pick the row insertion point from the focused window's
                // current vertical center (horizontal in portrait), so a
                // window dragged into a column "lands" next to the row
                // it's visually closest to instead of always at the bottom.
                let available = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
                let resolved = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
                let slotGap = CGFloat(resolved.inner.get(
                    layout.shape.orientation == .landscape ? .v : .h,
                ))
                let focusedRect = window.lastAppliedLayoutPhysicalRect
                    ?? layout.resolveRect(for: window.windowId, in: available, innerGap: slotGap)
                let center = focusedRect?.center ?? available.center
                let insertAt = layout.insertionSlot(in: targetLane, at: center, available: available, innerGap: slotGap)
                layout.insertSlot(in: targetLane, at: insertAt)
                layout.place(window.windowId, at: TileSpan(
                    lane0: targetLane, lane1: targetLane,
                    slot0: insertAt, slot1: insertAt,
                ))
            } else if layout.windows(in: myLane).count >= 2 {
                // Outward press at leftmost / rightmost column with 2+
                // rows → extract focused into a brand new column.
                // Siblings stay behind in the original lane.
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
                // Outward press at the leftmost / rightmost column with
                // no spare → shrink the focused column.
                GridMove.resizeLane(layout: layout, lane: myLane, signum: -1)
            }
        } else {
            // Slot axis (top/bottom in landscape, left/right in portrait)
            // mirrors the lane-axis edge fallback: at the slot edge with
            // no neighbour, shrink the focused row instead of extending.
            // Off-screen presses never create new rows; users can grow a
            // row back with cmd-alt-arrows (the resize ladder).
            let myLane = current.lane0
            let mySlot = signum > 0 ? current.slot1 : current.slot0
            let slots = layout.slotCount(in: myLane)
            let neighborSlot = signum > 0 ? mySlot + 1 : mySlot - 1
            if neighborSlot >= 0 && neighborSlot < slots {
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
