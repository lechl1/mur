import AppKit
import Common
import Foundation

/// `mur grid-move <left|down|up|right>` — move the focused window one
/// tile in the given cardinal direction.
///
/// Lane axis (left/right in landscape, up/down in portrait) uses a
/// **bloom-and-contract** sequence so a series of presses traces a
/// natural arc across the grid:
///
///   start lane 0     pressing right →
///       (0,0) → (0,1) → (0,2) → (1,2) → (2,2)
///       1-wide   2-wide  3-wide  2-wide  1-wide
///
/// Symmetric in reverse: pressing left from (2,2) walks back along the
/// same chain. The window grows by extending the trailing edge while it
/// has room, then contracts from the leading edge once it hits the far
/// wall. This gives the user a visible "wave" through the grid instead
/// of teleporting from edge to edge.
///
/// Slot axis (up/down in landscape, left/right in portrait) keeps the
/// simple single-step semantics:
///   - upward / leftward → slot0 -= 1, clamped at 0.
///   - downward / rightward → slot0 += 1, lane extends past the bottom.
///   - slotCount is preserved across the move.
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
        // Translate the cardinal direction into (axis, signum) given the
        // current orientation. `isLaneAxis` selects the bloom path; the
        // slot axis stays single-step.
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

        var newLane0 = current.lane0
        var newLane1 = current.lane1
        var newSlot0 = current.slot0
        var newSlot1 = current.slot1

        if isLaneAxis {
            (newLane0, newLane1) = GridMove.bloomLaneStep(
                lane0: current.lane0, lane1: current.lane1,
                lanes: shape.lanes, signum: signum,
            )
        } else {
            // Slot axis: single-step shift, preserving slotCount. Down /
            // rightward past the bottom extends the lane.
            if signum > 0 {
                newSlot0 = current.slot0 + 1
                newSlot1 = newSlot0 + (current.slot1 - current.slot0)
            } else {
                newSlot0 = max(0, current.slot0 - 1)
                newSlot1 = newSlot0 + (current.slot1 - current.slot0)
            }
        }

        let span = TileSpan(lane0: newLane0, lane1: newLane1, slot0: newSlot0, slot1: newSlot1)
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

/// Pure step functions for `grid-move`. Factored out for unit testing.
enum GridMove {
    /// One step of the bloom-and-contract walk along the lane axis.
    /// Returns the next `(lane0, lane1)` given the current state and a
    /// signum (+1 for "right/down toward higher index", -1 for the
    /// opposite). The walk is symmetric: applying `+1` then `-1` from
    /// any state returns to the same state.
    ///
    /// Rule:
    ///   signum > 0:
    ///     * if `lane1 < lanes-1` → grow trailing edge (lane1 += 1)
    ///     * else if `lane0 < lane1` → shrink leading edge (lane0 += 1)
    ///     * else (already at single-cell extreme) → no-op
    ///   signum < 0: mirrored.
    static func bloomLaneStep(lane0: Int, lane1: Int, lanes: Int, signum: Int) -> (Int, Int) {
        precondition(lane0 <= lane1 && lane0 >= 0 && lane1 < lanes,
                     "bloomLaneStep: invalid input (\(lane0), \(lane1)) in \(lanes) lanes")
        if signum > 0 {
            if lane1 < lanes - 1 { return (lane0, lane1 + 1) }
            if lane0 < lane1     { return (lane0 + 1, lane1) }
            return (lane0, lane1)
        } else {
            if lane0 > 0         { return (lane0 - 1, lane1) }
            if lane1 > lane0     { return (lane0, lane1 - 1) }
            return (lane0, lane1)
        }
    }
}
