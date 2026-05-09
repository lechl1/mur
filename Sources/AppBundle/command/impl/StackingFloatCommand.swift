import AppKit
import Common
import Foundation

/// `mur stacking-float` — pull the focused (or `--window-id`) window out
/// of the workspace's grid and re-bind it as floating. Also forgets
/// the matching `WindowMemory` entry so a subsequent reopen of the
/// same app+title doesn't auto-restore into the grid.
///
/// To re-tile a floating window, run `mur stacking-place <lane> <slot0> <slot1>`.
struct StackingFloatCommand: Command {
    let args: StackingFloatCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard config.experimentalStackingLayout else {
            io.err("stacking-float requires `experimental-stacking-layout = true` in mur.toml")
            return .fail
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            io.err("stacking-float needs a focused window or --window-id <id>")
            return .fail
        }
        let workspace = target.workspace
        let layout = workspace.stackingLayout
        guard layout.placements[window.windowId] != nil else {
            io.err("window \(window.windowId) is not in the grid (already floating or unmanaged)")
            return .fail
        }
        layout.remove(window.windowId)
        window.bindAsFloatingWindow(to: workspace)
        // Async work: center the window on its monitor + persist the
        // memory clearance. Both touch AX or disk; do them off the
        // request-handling path.
        Task { @MainActor in
            // Center the now-floating window on the workspace's monitor.
            // Use the current AX size if we can read it, else fall back
            // to a conservative half-monitor square.
            let monRect = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
            let size: CGSize = (try? await window.getAxRect())?.size
                ?? window.lastFloatingSize
                ?? CGSize(width: monRect.width / 2, height: monRect.height / 2)
            let cx = monRect.topLeftX + (monRect.width - size.width) / 2
            let cy = monRect.topLeftY + (monRect.height - size.height) / 2
            window.setAxFrame(CGPoint(x: cx, y: cy), size)

            let appId = window.app.rawAppBundleId ?? ""
            let title = (try? await window.title) ?? ""
            windowMemory.forget(appId: appId, title: title, shape: layout.shape)
            windowMemory.save()
        }
        return .succ
    }
}
