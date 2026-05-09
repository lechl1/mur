import AppKit
import Common
import Foundation

/// `mur grid-move <left|down|up|right>` — move the focused window one
/// tile in the given cardinal direction.
///
///   left   lane -= 1, slot stays the same (clamped to first slot of new lane).
///   right  lane += 1, slot stays the same (clamped likewise).
///   up     slot -= 1 within current lane.
///   down   slot += 1 within current lane. Past the last slot, the lane
///          gains a new slot at the bottom.
///
/// Lane changes that hit the edge clamp at 0 / `lanes-1` (no wrap).
/// Slot changes that hit the top clamp at 0 (no wrap); the bottom
/// extends rather than clamps.
struct GridMoveCommand: Command {
    let args: GridMoveCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard config.experimentalGridLayout else {
            io.err("grid-move requires `experimental-grid-layout = true` in mur.toml")
            return .fail
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            io.err("grid-move needs a focused window or --window-id <id>")
            return .fail
        }
        let workspace = target.workspace
        let layout = workspace.gridLayout
        guard let current = layout.placements[window.windowId] else {
            io.err("window \(window.windowId) is not in the grid (use grid-place to add it)")
            return .fail
        }

        let shape = layout.shape
        var newLane = current.lane
        var newSlot0 = current.slot0
        var newSlot1 = current.slot1
        switch args.direction.val {
            case .left:
                newLane = max(0, current.lane - 1)
            case .right:
                newLane = min(shape.lanes - 1, current.lane + 1)
            case .up:
                newSlot0 = max(0, current.slot0 - 1)
                newSlot1 = newSlot0 + (current.slot1 - current.slot0)
            case .down:
                // Past the bottom: extend the lane by appending a slot.
                let lastSlot = layout.slotCount(in: current.lane) - 1
                if current.slot1 >= lastSlot {
                    newSlot0 = current.slot0 + 1
                } else {
                    newSlot0 = current.slot0 + 1
                }
                newSlot1 = newSlot0 + (current.slot1 - current.slot0)
        }

        let span = TileSpan(lane: newLane, slot0: newSlot0, slot1: newSlot1)
        layout.place(window.windowId, at: span)
        Task { @MainActor in
            let appId = window.app.rawAppBundleId ?? ""
            let title = (try? await window.title) ?? ""
            windowMemory.remember(appId: appId, title: title, shape: shape, span: span)
            windowMemory.save()
        }
        return .succ
    }
}
