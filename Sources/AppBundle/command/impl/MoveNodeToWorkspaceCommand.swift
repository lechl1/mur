import AppKit
import Common

struct MoveNodeToWorkspaceCommand: Command {
    let args: MoveNodeToWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        let subjectWs = window.nodeWorkspace
        let targetWorkspace: Workspace
        switch args.target.val {
            case .relative(let nextPrev):
                guard let subjectWs else { return .fail(io.err("Window \(window.windowId) doesn't belong to any workspace")) }
                let ws = getNextPrevWorkspace(
                    current: subjectWs,
                    isNext: nextPrev == .next,
                    wrapAround: args.wrapAround,
                    stdin: args.useStdin ? io.readStdin() : nil,
                    target: target,
                )
                guard let ws else { return .fail(io.err("Can't resolve next or prev workspace")) }
                targetWorkspace = ws
            case .direct(let name):
                targetWorkspace = Workspace.get(byName: name.raw)
        }
        return moveWindowToWorkspace(window, targetWorkspace, io, focusFollowsWindow: args.focusFollowsWindow, failIfNoop: args.failIfNoop)
    }
}

@MainActor
func moveWindowToWorkspace(
    _ window: Window,
    _ targetWorkspace: Workspace,
    _ io: CmdIo,
    focusFollowsWindow: Bool,
    failIfNoop: Bool,
    index: Int = INDEX_BIND_LAST,
    mountInGrid: Bool = true,
    sourceRect: Rect? = nil,
    entry: CGPoint? = nil,
) -> BinaryExitCode {
    if window.nodeWorkspace == targetWorkspace {
        return switch failIfNoop {
            case true: .fail
            case false:
                .succ(io.err("Window '\(window.windowId)' already belongs to workspace '\(targetWorkspace.name)'. Tip: use --fail-if-noop to exit with non-zero code"))
        }
    }
    // Read before the window leaves its grid; callers that took it out
    // themselves pass it. Its column of its own there gets the size it had
    // when this run of moves began (`MoveSizeMemory`).
    let sourceRect = startMove(of: window, renderedAt: sourceRect ?? window.nodeWorkspace.flatMap { gridRect(of: window, in: $0) })
    _ = window.nodeWorkspace?.stackingLayout.remove(window.windowId)
    let targetContainer: NonLeafTreeNodeObject = window.isFloating ? targetWorkspace : targetWorkspace.rootTilingContainer
    window.bind(to: targetContainer, adaptiveWeight: WEIGHT_AUTO, index: index)
    // mur — the grid, not the tree, decides where a window renders. Without a
    // cell on the destination it gets no rect: it stays wherever it was (or
    // hidden) and never joins the columns. Callers that place the window
    // themselves pass `mountInGrid: false`. A tiled window gets a column of
    // its own at the width it had (`mountInOwnColumn`), not the new-window
    // heuristic, which stacked it under the focused column at that
    // column's width.
    if mountInGrid {
        if config.experimentalStackingLayout, !window.isFloating {
            mountInOwnColumn(window, in: targetWorkspace, keeping: sourceRect, entry: entry)
        } else {
            mountMovedWindowInGrid(window, in: targetWorkspace)
        }
    }
    // The column it joined halfway on the old workspace gets its width back.
    restoreColumnLeft(by: window)
    return .from(bool: focusFollowsWindow ? window.focusWindow() : true)
}
