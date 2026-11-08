import AppKit
import Common

/// mur — the workspace each app last had focus on, by pid. A process with
/// windows on several workspaces is placed by the one it was last used on.
@MainActor var lastFocusedWorkspaceNameByPid: [pid_t: String] = [:]

/// mur — a window opened while mur runs lands on the workspace of the
/// process that started it: the nearest ancestor process that owns a
/// window mur manages (`just dev` in a terminal on workspace 2 opens its
/// app on 2, not on whichever workspace has focus by then). `nil` when no
/// ancestor has a window — an app from the Dock, Finder or `open`, whose
/// parent is launchd — and the caller falls back to the focused workspace.
@MainActor
func workspaceOfParentProcess(of pid: pid_t) -> Workspace? {
    var workspacesByPid: [pid_t: Set<String>] = [:]
    for window in MacWindow.allWindows {
        guard let workspace = window.nodeWorkspace else { continue }
        workspacesByPid[window.app.pid, default: []].insert(workspace.name)
    }
    let name = parentProcessWorkspaceName(
        of: pid,
        parentOf: parentPid,
        workspacesOf: { workspacesByPid[$0] ?? [] },
        lastFocusedOf: { lastFocusedWorkspaceNameByPid[$0] },
        focused: focus.workspace.name,
    )
    return name.map { Workspace.get(byName: $0) }
}

/// The walk behind `workspaceOfParentProcess`, kept free of mur's state so
/// it can be tested. Starts at `pid`'s parent (the app's own other windows
/// don't count) and stops at launchd. Of an ancestor's several workspaces:
/// the one it last had focus on, else the focused one, else the first by name.
func parentProcessWorkspaceName(
    of pid: pid_t,
    parentOf: (pid_t) -> pid_t?,
    workspacesOf: (pid_t) -> Set<String>,
    lastFocusedOf: (pid_t) -> String?,
    focused: String,
) -> String? {
    var ancestor = parentOf(pid)
    var seen: Set<pid_t> = [pid]
    while let current = ancestor, current > 1, seen.insert(current).inserted {
        let names = workspacesOf(current)
        if !names.isEmpty {
            if let last = lastFocusedOf(current), names.contains(last) { return last }
            if names.contains(focused) { return focused }
            return names.min()
        }
        ancestor = parentOf(current)
    }
    return nil
}

/// The parent of `pid`, from the kernel's process table.
func parentPid(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let ppid = info.kp_eproc.e_ppid
    return ppid > 0 ? ppid : nil
}
