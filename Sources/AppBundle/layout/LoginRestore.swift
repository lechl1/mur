import AppKit
import Common
import Foundation

/// mur — WINDOWS macOS REOPENED AT LOGIN ARE PART OF THE RESTORE.
///
/// With "Reopen windows when logging back in", loginwindow relaunches the
/// apps of the last session in a burst right after login, and each app puts
/// its windows back at the frames it saved. mur starts at login too, so its
/// first coordinated restore runs before most of those windows exist: they
/// register later and would count as windows the user opened while mur was
/// running — kept on the active workspace, never steered on an app-pool
/// guess. A window whose app was launched in the login burst wasn't opened
/// by the user, so it is restored like the startup batch instead.
///
/// Only while restore mode is on (`isRestoringWindowState`): once the
/// remembered windows are claimed or `restoreSettle` ran out, a window is
/// new again whatever its app's launch date.
@MainActor
func wasReopenedAtLogin(_ window: Window) -> Bool {
    guard isRestoringWindowState, let app = window.app as? MacApp else { return false }
    return isLoginBurstLaunch(app: app.nsApp.launchDate, login: consoleLoginDate)
}

/// How long after login an app launch still counts as macOS reopening the
/// last session. The burst observed here takes under 10s; the margin covers
/// a slow disk and the login items launching alongside it.
let loginBurst: TimeInterval = 60

/// Whether an app launched at `app` belongs to the login burst that started
/// at `login`. Pure, so it can be tested.
func isLoginBurstLaunch(app: Date?, login: Date?) -> Bool {
    guard let app, let login else { return false }
    return app >= login && app.timeIntervalSince(login) <= loginBurst
}

/// When this user's console session began: the newest `console` login
/// record in utmpx (what `who` prints). Read once — it doesn't change while
/// mur runs, and a restarted mur reads it again.
@MainActor private let consoleLoginDate: Date? = {
    let user = NSUserName()
    var newest: Date?
    setutxent()
    defer { endutxent() }
    while let entry = getutxent() {
        guard entry.pointee.ut_type == USER_PROCESS,
              cString(entry.pointee.ut_line) == "console",
              cString(entry.pointee.ut_user) == user else { continue }
        let tv = entry.pointee.ut_tv
        let date = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
        if newest.map({ date > $0 }) ?? true { newest = date }
    }
    return newest
}()

/// A fixed-size C char array (utmpx field) as a String.
private func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}
