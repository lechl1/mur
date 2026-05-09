import AppKit
import Common
import Foundation

/// `mur grid-move <left|down|up|right>` — **resize** the focused
/// window's column / row in the press direction. Despite the name,
/// this command no longer moves the window; movement lives on
/// `mur grid-swap`. Renaming would break existing keybindings, so
/// the spelling is kept.
///
///   - landscape: left/right shrink/grow the column; up/down shrink/grow
///     the row within the focused lane.
///   - portrait flips the axes.
///
/// The resize walks a discrete fraction ladder (1/16 ↔ 1/2 ↔ 15/16) so
/// repeated presses snap to recognisable proportions. The freed (or
/// borrowed) weight is distributed across the other used lanes / slots
/// proportionally to keep the partition tight and never sends any
/// lane / slot below 1/16.
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
            GridMove.resizeLane(layout: layout, lane: current.lane0, signum: signum)
        } else {
            GridMove.resizeSlot(layout: layout, lane: current.lane0, slot: current.slot0, signum: signum)
        }
        // Window doesn't move; HUD reflects the new lane / slot weights
        // (it queries `layout.laneWeight` / `slotWeight` on update).
        GridHud.shared.update(layout: layout, span: current)
        Task { @MainActor in
            let appId = window.app.rawAppBundleId ?? ""
            let title = (try? await window.title) ?? ""
            windowMemory.remember(appId: appId, title: title, shape: shape, span: current)
            windowMemory.save()
        }
        return .succ
    }
}

/// Pure resize functions for `grid-move`. Factored out for unit testing.
enum GridMove {
    /// Discrete ladder of fractions the resize snaps to. Values run
    /// 1/16, 1/15, …, 1/3, 1/2, 2/3, 3/4, …, 15/16 — symmetric around
    /// 1/2. A press in the shrink direction picks the next-smaller
    /// rung, a press in the grow direction picks the next-larger.
    static let resizeFractionLadder: [CGFloat] = {
        var ladder: [CGFloat] = []
        let MAX_N = 16
        // Shrink half: 1/MAX_N → 1/2.
        for n in (2...MAX_N).reversed() {
            ladder.append(1.0 / CGFloat(n))
        }
        // Grow half: 2/3 → (MAX_N-1)/MAX_N. (1/2 already in ladder.)
        for n in 3...MAX_N {
            ladder.append(CGFloat(n - 1) / CGFloat(n))
        }
        return ladder
    }()

    /// Index in `resizeFractionLadder` of the rung closest to `f`.
    static func nearestLadderIndex(for f: CGFloat) -> Int {
        var bestIdx = 0
        var bestDist = abs(resizeFractionLadder[0] - f)
        for i in 1..<resizeFractionLadder.count {
            let d = abs(resizeFractionLadder[i] - f)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        return bestIdx
    }

    /// Resize `lane` by stepping along `resizeFractionLadder`. `signum`
    /// > 0 grows; < 0 shrinks. The freed (or borrowed) weight is
    /// distributed proportionally across other used lanes. No-op if
    /// fewer than 2 used lanes (no others to absorb / donate).
    static func resizeLane(layout: GridLayout, lane: Int, signum: Int) {
        let used = layout.usedLanes
        guard used.count >= 2, lane >= 0, lane < layout.shape.lanes else { return }
        var weights: [CGFloat] = []
        for l in 0..<layout.shape.lanes { weights.append(layout.laneWeight(lane: l)) }
        let usedTotal = used.reduce(0.0) { $0 + weights[$1] }
        guard usedTotal > 0 else { return }
        let w = weights[lane]
        guard w > 0 else { return }
        let f = w / usedTotal
        let target = stepLadder(from: f, signum: signum)
        guard target != f else { return }
        let newW = target * usedTotal
        let delta = newW - w
        let sumOthers = usedTotal - w
        guard sumOthers > 0 else { return }
        weights[lane] = newW
        for l in used where l != lane {
            weights[l] -= delta * (weights[l] / sumOthers)
        }
        if weights.contains(where: { $0 <= 0 }) { return }
        layout.setLaneWeights(weights)
    }

    /// Resize `slot` within `lane`. Same ladder semantics as `resizeLane`.
    static func resizeSlot(layout: GridLayout, lane: Int, slot: Int, signum: Int) {
        guard 0 <= lane, lane < layout.shape.lanes else { return }
        let slots = layout.slotCount(in: lane)
        guard slots >= 2, slot >= 0, slot < slots else { return }
        var weights: [CGFloat] = []
        for s in 0..<slots { weights.append(layout.slotWeight(lane: lane, slot: s)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return }
        let w = weights[slot]
        guard w > 0 else { return }
        let f = w / total
        let target = stepLadder(from: f, signum: signum)
        guard target != f else { return }
        let newW = target * total
        let delta = newW - w
        let sumOthers = total - w
        guard sumOthers > 0 else { return }
        weights[slot] = newW
        for s in 0..<slots where s != slot {
            weights[s] -= delta * (weights[s] / sumOthers)
        }
        if weights.contains(where: { $0 <= 0 }) { return }
        layout.setSlotWeights(lane: lane, weights: weights)
    }

    private static func stepLadder(from f: CGFloat, signum: Int) -> CGFloat {
        let idx = nearestLadderIndex(for: f)
        let target = signum > 0 ? idx + 1 : idx - 1
        guard target >= 0, target < resizeFractionLadder.count else { return f }
        return resizeFractionLadder[target]
    }
}
