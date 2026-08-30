import AppKit
import Common
import Foundation

/// `mur stacking-resize-lane <grow|shrink>` — resize the focused window's
/// LANE along the rigid axis, explicitly rather than positionally.
///
///   - landscape: lanes are columns → `grow` widens the column;
///   - portrait: lanes are rows → `grow` makes the row taller.
///
/// The width is ABSOLUTE (`resizeLaneAbsolute`, the same path the mouse
/// resize takes), so fit-or-center re-centres the strip: the column grows
/// and shrinks symmetrically about the screen centre and the neighbours
/// keep their own widths. The slot axis (rows within a column) is
/// untouched — that stays on `stacking-resize up/down`.
struct StackingResizeLaneCommand: Command {
    let args: StackingResizeLaneCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard config.experimentalStackingLayout else {
            io.err("stacking-resize-lane requires `experimental-stacking-layout = true` in mur.toml")
            return .fail
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            io.err("stacking-resize-lane needs a focused window or --window-id <id>")
            return .fail
        }
        let workspace = target.workspace
        let layout = workspace.stackingLayout
        // Same affordance as `stacking-resize`: a floating window joins the
        // grid on the first press, and resizes from the second on.
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
                persistWindowStateSoon()
            // Siblings' slots shift with a move/resize too — sweep the layout.
            persistWindowStateSoon()
            }
            return .succ
        }
        guard let current = layout.placements[window.windowId] else {
            io.err("window \(window.windowId) is not in the grid (use stacking-place to add it)")
            return .fail
        }

        StackingResize.resizeLaneAbsolute(layout: layout, lane: current.lane0, signum: args.delta.val.signum)
        // The window doesn't move; the HUD re-reads the lane weights.
        StackingHud.shared.update(layout: layout, span: current)
        Task { @MainActor in
            let appId = window.app.rawAppBundleId ?? ""
            let title = (try? await window.title) ?? ""
            windowMemory.remember(appId: appId, title: title, workspace: workspace.name, shape: layout.shape, span: current)
            windowMemory.save()
            // Siblings' slots shift with a move/resize too — sweep the layout.
            persistWindowStateSoon()
        }
        return .succ
    }
}
