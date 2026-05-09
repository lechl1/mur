import AppKit
import Common
import Foundation

/// `mur grid-place <lane> <slot0> <slot1>` — place the focused window
/// (or `--window-id <id>`) at the given grid span. Updates
/// `WindowMemory` so reopens of the same app+title come back here.
///
/// Errors:
///  • No experimental-grid-layout flag → fails with a hint to enable it.
///  • No focused window / --window-id → fails with usage hint.
///  • Lane out of range → fails with shape info.
///  • slot0 > slot1 → fails (TileSpan invariant).
struct GridPlaceCommand: Command {
    let args: GridPlaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard config.experimentalGridLayout else {
            io.err("grid-place requires `experimental-grid-layout = true` in mur.toml")
            return .fail
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            io.err("grid-place needs a focused window or --window-id <id>")
            return .fail
        }
        let workspace = target.workspace
        let lane = args.lane.val
        let slot0 = args.slot0.val
        let slot1 = args.slot1.val

        let shape = workspace.gridLayout.shape
        guard lane >= 0 && lane < shape.lanes else {
            io.err("lane \(lane) out of range; valid range is 0..<\(shape.lanes)")
            return .fail
        }
        guard slot0 <= slot1 else {
            io.err("slot0 (\(slot0)) must be <= slot1 (\(slot1))")
            return .fail
        }

        let span = TileSpan(lane: lane, slot0: slot0, slot1: slot1)
        workspace.gridLayout.place(window.windowId, at: span)

        // Persist to WindowMemory so future opens of the same app+title
        // restore here. Title fetch is async; do it best-effort.
        Task { @MainActor in
            let appId = window.app.rawAppBundleId ?? ""
            let title = (try? await window.title) ?? ""
            windowMemory.remember(appId: appId, title: title, shape: shape, span: span)
            windowMemory.save()
        }

        return .succ
    }
}
