import AppKit
import Common

/// mur — an app started in the background doesn't take focus. depot quits an
/// app it reinstalls and reopens it with `open <bundle>`; the app activates
/// as it starts, and mur used to follow macOS's focus to it — onto its
/// workspace, away from what the user was doing.
///
/// LaunchServices records which app asked for each launch (`lsappinfo`'s
/// `parentASN`): Dock, Spotlight, Finder, Raycast, loginwindow. A launch
/// through `open` (depot, a script, a terminal) or by launchd has none, and
/// its process's parent is launchd. An app run straight from a terminal
/// (`just dev`) has none either, but its parent is the shell: that one is
/// the user's and keeps focus. For
/// `BackgroundLaunch.grace` after such a launch, and until the user clicks,
/// mur leaves focus where it is when macOS hands it to that app, and gives
/// macOS's focus back to the focused window.
enum BackgroundLaunch {
    static let grace: TimeInterval = 10

    /// Pure: whether a native focus move onto an app's window is declined.
    static func declinesFocus(
        startedInBackground: Bool?,
        launchDate: Date?,
        lastUserClick: Date?,
        now: Date,
    ) -> Bool {
        guard startedInBackground == true, let launchDate else { return false } // unknown → follow, as before
        if now.timeIntervalSince(launchDate) > grace { return false }
        if let lastUserClick, lastUserClick >= launchDate { return false }
        return true
    }
}

/// The last left click anywhere: the user reaching for a window, which a
/// background launch then gets to keep.
@MainActor var lastUserClickDate: Date? = nil

extension MacApp {
    /// No app asked for this launch and launchd is its parent. `nil` when
    /// the private API isn't there (a future macOS).
    @MainActor var wasStartedInBackground: Bool? {
        let pid = nsApp.processIdentifier
        if let cached = startedInBackgroundCache[pid] { return cached }
        let value: Bool? = launchServicesHasParentApp(pid: pid).map { hasLauncher in
            !hasLauncher && parentPid(pid) == 1
        }
        startedInBackgroundCache[pid] = value
        return value
    }
}

@MainActor private var startedInBackgroundCache: [pid_t: Bool?] = [:]

@MainActor func forgetLaunchOrigin(pid: pid_t) {
    startedInBackgroundCache.removeValue(forKey: pid)
}

/// Whether native focus moving to `window` should be declined (see
/// `BackgroundLaunch`).
@MainActor func declinesBackgroundLaunchFocus(_ window: Window) -> Bool {
    guard let app = window.app as? MacApp, focus.windowOrNil?.app.pid != app.pid else { return false }
    let launchDate = app.nsApp.launchDate
    // Only ask LaunchServices about an app that just started.
    guard let launchDate, Date.now.timeIntervalSince(launchDate) <= BackgroundLaunch.grace else { return false }
    return BackgroundLaunch.declinesFocus(
        startedInBackground: app.wasStartedInBackground,
        launchDate: launchDate,
        lastUserClick: lastUserClickDate,
        now: .now,
    )
}

// _LSCopyApplicationInformation / _LSASNCreateWithPid: private, stable for
// years; what `lsappinfo` itself uses. Looked up at runtime so a macOS that
// drops them only loses this feature.
private typealias LSASNCreateWithPid = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
private typealias LSCopyApplicationInformation = @convention(c) (Int32, CFTypeRef?, CFArray?) -> Unmanaged<CFDictionary>?
private let kLSDefaultSessionID: Int32 = -2

private let launchServices: (create: LSASNCreateWithPid, copy: LSCopyApplicationInformation)? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY),
          let create = dlsym(handle, "_LSASNCreateWithPid"),
          let copy = dlsym(handle, "_LSCopyApplicationInformation")
    else { return nil }
    return (unsafeBitCast(create, to: LSASNCreateWithPid.self), unsafeBitCast(copy, to: LSCopyApplicationInformation.self))
}()

private func launchServicesHasParentApp(pid: pid_t) -> Bool? {
    guard let launchServices, let asn = launchServices.create(nil, pid)?.takeRetainedValue() else { return nil }
    guard let info = launchServices.copy(kLSDefaultSessionID, asn, nil)?.takeRetainedValue() as? [String: Any] else { return nil }
    return info["LSParentASN"] != nil
}
