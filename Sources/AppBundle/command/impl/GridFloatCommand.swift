import AppKit
import Common
import Foundation

/// `mur grid-float` — pull the focused (or `--window-id`) window out
/// of the workspace's grid and re-bind it as floating. Also forgets
/// the matching `WindowMemory` entry so a subsequent reopen of the
/// same app+title doesn't auto-restore into the grid.
///
/// To re-tile a floating window, run `mur grid-place <lane> <slot0> <slot1>`.
struct GridFloatCommand: Command {
    let args: GridFloatCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard config.experimentalGridLayout else {
            io.err("grid-float requires `experimental-grid-layout = true` in mur.toml")
            return .fail
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            io.err("grid-float needs a focused window or --window-id <id>")
            return .fail
        }
        let workspace = target.workspace
        let layout = workspace.gridLayout
        guard layout.placements[window.windowId] != nil else {
            io.err("window \(window.windowId) is not in the grid (already floating or unmanaged)")
            return .fail
        }
        layout.remove(window.windowId)
        Task { @MainActor in
            let appId = window.app.rawAppBundleId ?? ""
            let title = (try? await window.title) ?? ""
            windowMemory.forget(appId: appId, title: title, shape: layout.shape)
            windowMemory.save()
        }
        window.bindAsFloatingWindow(to: workspace)
        return .succ
    }
}
