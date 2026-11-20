import AppKit
import Common

/// mur — A RELAUNCHED APP'S WINDOWS GO BACK TO THEIR WORKSPACES.
///
/// `depot sync` / `depot install` quits an app it replaces and opens it
/// again (`open <bundle>`). The new process's parent is launchd, so
/// `workspaceOfParentProcess` has nothing to say and every window landed
/// on the focused workspace. mur remembers when each app quit; a window
/// that app opens within `relaunchWindow` goes to the workspace its ghost
/// is on in the saved arrangement (`ArrangementStore.ghostWorkspace`): the
/// ghost with its title, else the app's ghosts if they're all on one
/// workspace. A window opened any other time still joins the workspace the
/// user is on: steering a window the user just opened made it vanish.
@MainActor
struct RelaunchedApps {
    /// Long enough for a quit, a `brew reinstall` (download included) and a
    /// reopen.
    static let relaunchWindow: TimeInterval = 600

    private var terminatedAt: [String: Date] = [:]

    mutating func noteTerminated(_ appId: String, at now: Date = .now) {
        terminatedAt[appId] = now
    }

    func isRelaunch(_ appId: String, at now: Date = .now) -> Bool {
        guard let t = terminatedAt[appId] else { return false }
        return now.timeIntervalSince(t) <= Self.relaunchWindow
    }
}

@MainActor var relaunchedApps = RelaunchedApps()

/// The workspace a window of a just-relaunched app goes back to; nil when
/// the app didn't just quit or nothing names a workspace for this window.
@MainActor
func workspaceOfRelaunchedApp(_ macApp: MacApp, windowId: UInt32) async -> Workspace? {
    guard let appId = macApp.rawAppBundleId, relaunchedApps.isRelaunch(appId) else { return nil }
    let raw = (try? await macApp.getAxTitle(windowId)) ?? ""
    let name = arrangementStore.ghostWorkspace(
        appId: appId,
        title: normalizedSessionTitle(raw) ?? raw,
        isPlaced: { id in Workspace.all.contains { $0.stackingLayout.placements[id] != nil } },
    )
    return name.map { Workspace.get(byName: $0) }
}
