import AppKit
import Common
import Foundation

/// `mur grid-info` — print the grid layout state for the target workspace.
///
/// Output (one workspace per invocation):
///
///   workspace: 1
///   orientation: landscape
///   lanes: 3
///   used-lanes: [0, 2]
///   empty-lanes: [1]
///   placements: 3 (zOrder back→front)
///     [12345] lane=0 slot0=0 slot1=0 weight=[1.0]                (Mail)
///     [67890] lane=2 slot0=0 slot1=0 weight=[1.0]                (Slack)
///     [13579] lane=2 slot0=1 slot1=1 weight=[1.0]                (Slack)
///
/// `--workspace <name>` to inspect a specific workspace; otherwise the
/// focused workspace.
struct GridInfoCommand: Command {
    let args: GridInfoCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        let layout = workspace.gridLayout

        io.out("workspace: \(workspace.name)")
        io.out("orientation: \(layout.shape.orientation.rawValue)")
        io.out("lanes: \(layout.shape.lanes)")
        io.out("used-lanes: \(layout.usedLanes)")
        io.out("empty-lanes: \(layout.emptyLanes)")
        io.out("placements: \(layout.placements.count) (zOrder back→front)")

        for windowId in layout.zOrder {
            guard let span = layout.placements[windowId] else { continue }
            let appName = Window.get(byId: windowId)?.app.name ?? "?"
            // Show lane0's slot weights (canonical for multi-lane spans).
            let slots = layout.slotCount(in: span.lane0)
            var weights: [String] = []
            for s in 0..<slots {
                let w = layout.slotWeight(lane: span.lane0, slot: s)
                weights.append(String(format: "%.2f", w))
            }
            let weightsStr = "[" + weights.joined(separator: ", ") + "]"
            io.out("  [\(windowId)] lane0=\(span.lane0) lane1=\(span.lane1) slot0=\(span.slot0) slot1=\(span.slot1) weight=\(weightsStr) (\(appName))")
        }
        return .succ
    }
}
