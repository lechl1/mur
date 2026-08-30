import AppKit
import Common
import Foundation

/// `mur stacking-info` — print the grid layout state for the target workspace.
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
struct StackingInfoCommand: Command {
    let args: StackingInfoCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        let layout = workspace.stackingLayout

        let monitorRect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let gaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
        let slotGap = CGFloat(gaps.inner.get(layout.shape.orientation == .landscape ? .v : .h))

        io.out("workspace: \(workspace.name)")
        io.out("orientation: \(layout.shape.orientation.rawValue)")
        io.out("lanes: \(layout.shape.lanes)")
        io.out("used-lanes: \(layout.usedLanes)")
        io.out("empty-lanes: \(layout.emptyLanes)")
        // Lane weights are ABSOLUTE fractions of the lane axis; when the used
        // lanes total ≤ 1 the strip renders at those widths and is centered,
        // otherwise it's scaled down to fill. Printing both makes it obvious
        // which regime the layout is in.
        let usedWeights = layout.usedLanes.map { layout.laneWeight(lane: $0) }
        let totalWeight = usedWeights.reduce(0, +)
        let regime = totalWeight <= 1 ? "centered" : "fill"
        io.out("lane-weights: [" + usedWeights.map { String(format: "%.3f", $0) }.joined(separator: ", ") + "]" +
            String(format: " total=%.3f", totalWeight) + " (\(regime))")
        io.out(String(format: "monitor-rect: x=%.0f y=%.0f w=%.0f h=%.0f (inner-gap %.0f)",
                      monitorRect.topLeftX, monitorRect.topLeftY, monitorRect.width, monitorRect.height, slotGap))
        io.out("placements: \(layout.placements.count) (zOrder back→front)")

        for windowId in layout.zOrder {
            guard let span = layout.placements[windowId] else { continue }
            let appName = Window.get(byId: windowId)?.app.name ?? "?"
            let cell = layout.resolveRect(for: windowId, in: monitorRect, innerGap: slotGap)
            // Show lane0's slot weights (canonical for multi-lane spans).
            let slots = layout.slotCount(in: span.lane0)
            var weights: [String] = []
            for s in 0..<slots {
                let w = layout.slotWeight(lane: span.lane0, slot: s)
                weights.append(String(format: "%.2f", w))
            }
            let weightsStr = "[" + weights.joined(separator: ", ") + "]"
            let cellStr = cell.map { String(format: " cell=(x=%.0f w=%.0f)", $0.topLeftX, $0.width) } ?? ""
            io.out("  [\(windowId)] lane0=\(span.lane0) lane1=\(span.lane1) slot0=\(span.slot0) slot1=\(span.slot1) weight=\(weightsStr)\(cellStr) (\(appName))")
        }
        return .succ
    }
}
