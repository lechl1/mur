import AppKit
import Common
import Foundation

/// `mur grid-focus-dir <left|down|up|right>` — focus the spatial
/// neighbor of the currently-focused window inside the grid layout.
struct GridFocusDirCommand: Command {
    let args: GridFocusDirCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard config.experimentalGridLayout else {
            io.err("grid-focus-dir requires `experimental-grid-layout = true` in mur.toml")
            return .fail
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            io.err("grid-focus-dir needs a focused window")
            return .fail
        }
        let workspace = target.workspace
        let layout = workspace.gridLayout
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
