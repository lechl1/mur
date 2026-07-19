import AppKit
import Common
import Foundation

/// `mur stacking-resize <left|down|up|right>` — resize the focused
/// window's column / row **towards the centre**. The window itself stays
/// put; only lane / slot weights change. Window movement lives on
/// `mur stacking-move`.
///
///   - landscape: left/right shrink/grow the column WIDTH; up/down
///     shrink/grow the row height within the focused lane.
///   - portrait flips the axes.
///
/// Positional: the arrow pointing towards the centre of the grid grows,
/// the opposite shrinks. The COLUMN (lane) axis resizes by ABSOLUTE width
/// (`resizeLaneAbsolute`) so fit-or-center re-centres the strip — the
/// column grows / shrinks symmetrically about the screen centre. The ROW
/// (slot) axis, which fills the column, walks the discrete fraction
/// ladder (1/16 ↔ 1/2 ↔ 15/16), redistributing among the other rows.
struct StackingResizeCommand: Command {
    let args: StackingResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard config.experimentalStackingLayout else {
            io.err("stacking-resize requires `experimental-stacking-layout = true` in mur.toml")
            return .fail
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            io.err("stacking-resize needs a focused window or --window-id <id>")
            return .fail
        }
        let workspace = target.workspace
        let layout = workspace.stackingLayout
        // Floating window → register it into the grid on first keybinding
        // press. Subsequent presses then run the resize/move as usual.
        // This lets users "tile" a window with cmd-alt-arrow without
        // first invoking stacking-place explicitly.
        if layout.placements[window.windowId] == nil {
            let focusedLane = focus.windowOrNil
                .flatMap { layout.placements[$0.windowId]?.lane0 }
            let span = layout.placementForNewWindow(focusedLane: focusedLane)
            layout.place(window.windowId, at: span)
            StackingHud.shared.update(layout: layout, span: span)
            Task { @MainActor in
                let appId = window.app.rawAppBundleId ?? ""
                let title = (try? await window.title) ?? ""
                windowMemory.remember(appId: appId, title: title, workspace: workspace.name, shape: layout.shape, span: span)
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
        let rawSignum: Int
        switch (shape.orientation, args.direction.val) {
            case (.landscape, .left):  (isLaneAxis, rawSignum) = (true,  -1)
            case (.landscape, .right): (isLaneAxis, rawSignum) = (true,  +1)
            case (.landscape, .up):    (isLaneAxis, rawSignum) = (false, -1)
            case (.landscape, .down):  (isLaneAxis, rawSignum) = (false, +1)
            case (.portrait,  .up):    (isLaneAxis, rawSignum) = (true,  -1)
            case (.portrait,  .down):  (isLaneAxis, rawSignum) = (true,  +1)
            case (.portrait,  .left):  (isLaneAxis, rawSignum) = (false, -1)
            case (.portrait,  .right): (isLaneAxis, rawSignum) = (false, +1)
        }

        // Positional resize: the arrow key pointing towards the centre
        // of the grid grows the focused lane / slot, the opposite key
        // shrinks it. For a tile on the centre line, fall back to the
        // user-readable default — `right`/`up` grow, `left`/`down`
        // shrink (so a horizontal axis defaults to +1 grow direction
        // and a vertical axis to −1).
        let isLandscape = shape.orientation == .landscape
        let laneDefaultGrow = isLandscape ? +1 : -1   // lane axis is horizontal in landscape
        let slotDefaultGrow = isLandscape ? -1 : +1   // slot axis is vertical in landscape
        let used = layout.usedLanes
        let visIdx = used.firstIndex(of: current.lane0).map { Double($0) } ?? 0
        let laneCenter = Double(max(0, used.count - 1)) / 2.0
        let laneGrowSign: Int =
            visIdx < laneCenter ? +1 :
            visIdx > laneCenter ? -1 :
            laneDefaultGrow
        let slots = layout.slotCount(in: current.lane0)
        let slotCenter = Double(max(0, slots - 1)) / 2.0
        let slotPos = Double(current.slot0)
        let slotGrowSign: Int =
            slotPos < slotCenter ? +1 :
            slotPos > slotCenter ? -1 :
            slotDefaultGrow
        let growSignThisAxis = isLaneAxis ? laneGrowSign : slotGrowSign
        let signum = rawSignum == growSignThisAxis ? +1 : -1

        if isLaneAxis {
            // Resize-towards-centre: change the column's ABSOLUTE width so
            // fit-or-center re-centres the strip (matches the mouse resize).
            StackingResize.resizeLaneAbsolute(layout: layout, lane: current.lane0, signum: signum)
        } else {
            StackingResize.resizeSlot(layout: layout, lane: current.lane0, slot: current.slot0, signum: signum)
        }
        // Window doesn't move; HUD reflects the new lane / slot weights
        // (it queries `layout.laneWeight` / `slotWeight` on update).
        StackingHud.shared.update(layout: layout, span: current)
        Task { @MainActor in
            let appId = window.app.rawAppBundleId ?? ""
            let title = (try? await window.title) ?? ""
            windowMemory.remember(appId: appId, title: title, workspace: workspace.name, shape: shape, span: current)
            windowMemory.save()
        }
        return .succ
    }
}

/// Keyboard-driven resize helpers for `stacking-resize`. Sit alongside the
/// mouse-driven helpers already on `StackingResize`; factored out for unit
/// testing.
extension StackingResize {
    /// Discrete ladder of fractions the resize snaps to. Symmetric
    /// around 1/2. The base rungs are 1/N and (N-1)/N for N=2..16, and
    /// midpoints between every adjacent pair are inserted so a single
    /// press feels finer than the natural 1/N step (especially in the
    /// middle, where the gap between 1/2 and 1/3 is widest).
    static let resizeFractionLadder: [CGFloat] = {
        var base: [CGFloat] = []
        let MAX_N = 16
        for n in (2...MAX_N).reversed() { base.append(1.0 / CGFloat(n)) }
        for n in 3...MAX_N { base.append(CGFloat(n - 1) / CGFloat(n)) }
        var dense: [CGFloat] = []
        for (i, r) in base.enumerated() {
            dense.append(r)
            if i + 1 < base.count {
                dense.append((r + base[i + 1]) / 2.0)
            }
        }
        return dense
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
    ///
    /// Both the focused lane and every other used lane are floored at
    /// `usedTotal/16` (the ladder's minimum rung) and the focused
    /// lane is also capped at `usedTotal − (count−1) · minPerLane`.
    /// Without that, grow on one lane can push others well below the
    /// floor, leaving the grid in an extreme state that takes many
    /// presses to recover from. The post-distribution repair also
    /// self-heals any prior drift below the floor.
    static func resizeLane(layout: StackingLayout, lane: Int, signum: Int) {
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
        let minPer = usedTotal / 16
        let maxAllowed = usedTotal - CGFloat(used.count - 1) * minPer
        let newW = min(maxAllowed, max(minPer, target * usedTotal))
        let delta = newW - w
        guard abs(delta) > 1e-6 else { return }
        let sumOthers = usedTotal - w
        guard sumOthers > 0 else { return }
        weights[lane] = newW
        for l in used where l != lane {
            weights[l] -= delta * (weights[l] / sumOthers)
        }
        repairFloor(weights: &weights, used: used, minPer: minPer)
        if weights.contains(where: { $0 <= 0 }) { return }
        layout.setLaneWeights(weights)
    }

    /// Grow (`signum > 0`) / shrink (`signum < 0`) `lane`'s ABSOLUTE width
    /// by `step` (a fraction of the lane axis), clamped to `[0.1, 1.0]`.
    /// Unlike `resizeLane` (a constant-total ladder that redistributes
    /// among lanes), this changes ONLY this column's width — fit-or-center
    /// then re-centres the strip, so the column grows / shrinks
    /// symmetrically about the screen centre (naru resize-towards-centre).
    /// Works for a lone column too (the ladder version is a no-op there).
    static func resizeLaneAbsolute(layout: StackingLayout, lane: Int, signum: Int, step: CGFloat = 0.1) {
        guard lane >= 0, lane < layout.shape.lanes, layout.usedLanes.contains(lane) else { return }
        var weights: [CGFloat] = []
        for l in 0..<layout.shape.lanes { weights.append(layout.laneWeight(lane: l)) }
        let cur = weights[lane]
        let next = max(0.1, min(1.0, cur + CGFloat(signum) * step))
        guard abs(next - cur) > 1e-6 else { return }
        weights[lane] = next
        layout.setLaneWeights(weights)
    }

    /// Repair-floor pass: force every used weight to at least `minPer`,
    /// redistributing the lifted deficit proportionally from lanes /
    /// slots that are above the floor. Conserves total weight.
    static func repairFloor(weights: inout [CGFloat], used: [Int], minPer: CGFloat) {
        var deficit: CGFloat = 0
        for l in used where weights[l] < minPer {
            deficit += minPer - weights[l]
            weights[l] = minPer
        }
        guard deficit > 0 else { return }
        let donorAvailable = used.reduce(0.0) {
            $0 + max(0, weights[$1] - minPer)
        }
        guard donorAvailable > 0 else { return }
        for l in used where weights[l] > minPer {
            let avail = weights[l] - minPer
            weights[l] -= deficit * (avail / donorAvailable)
        }
    }

    /// Resize `slot` within `lane`. Same ladder semantics as `resizeLane`.
    /// Slot-axis equivalent of `resizeLane`'s floor + cap clamps.
    static func resizeSlot(layout: StackingLayout, lane: Int, slot: Int, signum: Int) {
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
        let minPer = total / 16
        let maxAllowed = total - CGFloat(slots - 1) * minPer
        let newW = min(maxAllowed, max(minPer, target * total))
        let delta = newW - w
        guard abs(delta) > 1e-6 else { return }
        let sumOthers = total - w
        guard sumOthers > 0 else { return }
        weights[slot] = newW
        for s in 0..<slots where s != slot {
            weights[s] -= delta * (weights[s] / sumOthers)
        }
        repairFloor(weights: &weights, used: Array(0..<slots), minPer: minPer)
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
