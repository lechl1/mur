import AppKit
import Common

/// See: MacosNativeFullscreenCommand. Problem ID-B6E178F2
struct MacosNativeMinimizeCommand: Command {
    let args: MacosNativeMinimizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        // resolveTargetOrReportError on already minimized windows will always fail
        // It would be easier if minimized windows were part of the workspace in tree hierarchy
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        let newState: Bool = try await !window.isMacosMinimized
        if newState {
            // mur — an explicit minimize opts out of the keep-columns-full
            // auto-restore in `normalizeLayoutReason`, and frees the cell so
            // the column collapses instead of standing empty.
            intentionallyMinimizedWindowIds.insert(window.windowId)
            for workspace in Workspace.all where workspace.stackingLayout.placements[window.windowId] != nil {
                _ = workspace.stackingLayout.remove(window.windowId)
            }
        }
        window.asMacWindow().setNativeMinimized(newState)
        if newState { // minimize
            // mur — record where the window came from BEFORE rebinding it.
            // Otherwise `normalizeLayoutReason` later stamps the shim
            // container itself as the previous parent, and un-minimizing
            // takes the "wtf case" branch, which never rejoins the grid —
            // the window comes back untiled, outside every column.
            if case .standard = window.layoutReason, let parent = window.parent {
                window.layoutReason = .macos(prevParentKind: parent.kind)
            }
            window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            return .succ
        } else { // unminimize
            return .fail(io.err("The command is uncapable of unminimizing windows yet. Sorry")) // dead code. should never be possible, see the comment above
        }
    }
}
