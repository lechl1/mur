import AppKit
import Common
import Foundation

/// `mur grid-focus <lane> <slot>` — focus the topmost window whose
/// `TileSpan` covers `(lane, slot)`. If no window is at that cell,
/// errors out without changing focus. Promotes the focused window to
/// the top of zOrder so it'll be the topmost on next refresh.
struct GridFocusCommand: Command {
    let args: GridFocusCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard config.experimentalGridLayout else {
            io.err("grid-focus requires `experimental-grid-layout = true` in mur.toml")
            return .fail
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        let layout = workspace.gridLayout
        let lane = args.lane.val
        let slot = args.slot.val

        // Walk zOrder back→front and pick the LAST (topmost) hit. Multi-
        // lane spans are hit when `lane` falls within `[lane0, lane1]`.
        var hit: WindowId? = nil
        for wid in layout.zOrder {
            guard let span = layout.placements[wid] else { continue }
            if span.lane0 <= lane && lane <= span.lane1
                && span.slot0 <= slot && slot <= span.slot1
            {
                hit = wid
            }
        }
        guard let topId = hit, let topWindow = Window.get(byId: topId) else {
            io.err("no grid window at lane=\(lane) slot=\(slot) on workspace \(workspace.name)")
            return .fail
        }
        topWindow.nativeFocus()
        layout.promote(topId)
        return .succ
    }
}
