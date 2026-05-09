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
        func distance(to span: TileSpan) -> Int? {
            switch axis {
                case .lane:
                    let delta = signum > 0 ? span.lane - current.lane : current.lane - span.lane
                    return delta > 0 ? delta : nil
                case .slot:
                    if span.lane != current.lane { return nil }
                    let delta = signum > 0 ? span.slot0 - current.slot1 : current.slot0 - span.slot1
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
        guard let best = candidates.min(by: { a, b in
            a.dist != b.dist ? a.dist < b.dist : a.zIdx > b.zIdx
        }) else {
            io.err("no grid window in direction \(args.direction.val.rawValue) from focused window")
            return .fail
        }
        guard let nextWindow = Window.get(byId: best.id) else { return .fail }
        nextWindow.nativeFocus()
        layout.promote(best.id)
        return .succ
    }
}
