import AppKit
import Common
import Foundation

/// mur — windows mur hid must not stay hidden once it's gone.
///
/// mur "hides" the windows of every workspace that isn't on screen by
/// parking them in a monitor's corner with 1px showing (`hideInCorner`);
/// macOS has no hidden-window state mur could use instead (see the README's
/// note on Spaces). Nothing but mur knows those windows are there, so every
/// way mur can stop has to put them back:
///
/// - a signal — `pkill`, `brew upgrade`, a terminal's ^C — through
///   `interceptTerminationSignals` (once only SIGINT, and only in debug
///   builds, so a plain `kill` left every hidden window in its corner);
/// - macOS quitting it — logout, restart, shutdown, the menu's Quit —
///   through `MurAppDelegate.applicationShouldTerminate`;
/// - and what neither can catch (a crash, SIGKILL): the next start reclaims
///   any window it finds parked off screen (`reclaimParkedWindow`).

/// The share of `rect`'s area that is on one of `screens`.
func visibleFraction(_ rect: Rect, on screens: [Rect]) -> CGFloat {
    let area = rect.width * rect.height
    guard area > 0 else { return 1 }
    let shown = screens.reduce(0.0) { sum, s in
        let w = max(0, min(rect.maxX, s.maxX) - max(rect.minX, s.minX))
        let h = max(0, min(rect.maxY, s.maxY) - max(rect.minY, s.minY))
        return sum + w * h
    }
    return min(1, shown / area)
}

/// A window with almost nothing on screen is one mur (or a mur that's no
/// longer running) parked in a corner.
func isParkedOffscreen(_ rect: Rect, on screens: [Rect]) -> Bool {
    visibleFraction(rect, on: screens) < 0.1
}

/// Where a parked window goes back to: centred in `visible`, no bigger than it.
func onscreenFrame(size: CGSize, in visible: Rect) -> (topLeft: CGPoint, size: CGSize) {
    let w = min(size.width, visible.width)
    let h = min(size.height, visible.height)
    return (CGPoint(x: visible.topLeftX + (visible.width - w) / 2, y: visible.topLeftY + (visible.height - h) / 2), CGSize(width: w, height: h))
}

/// Move every window mur parked back onto a screen. Windows already showing
/// stay exactly where they are. Bounded per window: an app that stopped
/// answering AX (see `withAxDeadline`) must not keep mur — and everyone
/// else's windows — from finishing.
@MainActor
func bringParkedWindowsBack() async {
    let screens = monitors.map(\.visibleRect)
    // In parallel, so one wedged app costs one deadline, not one per window.
    let tasks = MacWindow.allWindowsMap.keys.map { windowId in
        Task { @MainActor in
            do {
                try await withAxDeadline(nanoseconds: 1_000_000_000) {
                    guard let window = MacWindow.allWindowsMap[windowId],
                          let rect = try await window.getAxRect(),
                          window.isHiddenInCorner || isParkedOffscreen(rect, on: screens) else { return }
                    let monitor = rect.center.monitorApproximation
                    let frame = onscreenFrame(size: CGSize(width: rect.width, height: rect.height), in: monitor.visibleRect)
                    try await window.setAxFrameBlocking(frame.topLeft, frame.size)
                }
            } catch {
                // An app that doesn't answer in time keeps its window where it is.
            }
        }
    }
    for task in tasks { await task.value }
}

/// At startup: a window still parked off screen by a mur that didn't get to
/// clean up. Put it back in view; if its workspace isn't the one on screen,
/// the layout hides it again — this time remembering an on-screen spot.
@MainActor
func reclaimParkedWindow(_ window: MacWindow, rect: Rect?) {
    guard let rect else { return }
    let screens = monitors.map(\.visibleRect)
    guard isParkedOffscreen(rect, on: screens) else { return }
    let frame = onscreenFrame(size: CGSize(width: rect.width, height: rect.height), in: rect.center.monitorApproximation.visibleRect)
    window.setAxFrame(frame.topLeft, frame.size)
}

/// Signals stop mur through the same cleanup as a quit. A dispatch source
/// on the main queue, not a C signal handler: the cleanup is async
/// main-actor work, which a signal handler may not run.
@MainActor private var terminationSignalSources: [DispatchSourceSignal] = []

@MainActor
func interceptTerminationSignals(_ signals: [Int32]) {
    for sig in signals {
        signal(sig, SIG_IGN) // let the dispatch source have it
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            fireAndForget { @MainActor in
                defer { exit(128 + sig) }
                try await terminationHandler.beforeTermination()
            }
        }
        source.resume()
        terminationSignalSources.append(source)
    }
}

/// macOS asks an app to quit (logout, restart, shutdown, Quit) through its
/// delegate; answering `.terminateLater` buys the time to bring the parked
/// windows back first.
public final class MurAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        fireAndForget { @MainActor in
            defer { sender.reply(toApplicationShouldTerminate: true) }
            try await terminationHandler.beforeTermination()
        }
        return .terminateLater
    }
}
