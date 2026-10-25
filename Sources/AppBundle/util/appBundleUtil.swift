import AppKit
import Common
import Foundation
import os

// `nonisolated(unsafe)` works around macOS 14 SDK lacking Sendable on
// OSSignposter. signposters are inherently thread-safe (designed for
// concurrent logging from any thread). Drop this annotation once the
// minimum SDK is macOS 15.
nonisolated(unsafe) let signposter = OSSignposter(subsystem: aeroSpaceAppId, category: .pointsOfInterest)

let myPid = NSRunningApplication.current.processIdentifier
let lockScreenAppBundleId = "com.apple.loginwindow"

@MainActor
func initTerminationHandler() {
    unsafe _terminationHandler = AppServerTerminationHandler()
}

/// Set once the cleanup ran: a Quit runs it, then asks AppKit to terminate,
/// which asks the delegate, which would run it again.
@MainActor private var terminationCleanupDone = false

private struct AppServerTerminationHandler: TerminationHandler {
    func beforeTermination() async throws {
        if await MainActor.run(body: { terminationCleanupDone }) { return }
        await bringParkedWindowsBack()
        await MainActor.run { terminationCleanupDone = true }
        await toggleReleaseServerIfDebug(.on)
    }
}

/// mur — asks AppKit to quit from a run-loop block, not from the caller.
///
/// Callers are main-actor tasks, and a main-actor task runs as a block on
/// the main dispatch queue. `terminate` asks `MurAppDelegate`, which answers
/// `.terminateLater` and replies from another main-actor task, while AppKit
/// spins a nested run loop waiting for that reply. The run loop never drains
/// the main queue from inside one of its own blocks, so the reply never came
/// and mur hung in `terminate` instead of quitting. A run-loop block isn't a
/// main-queue block, so the nested loop can run the reply.
@MainActor
func terminateApp() {
    RunLoop.main.perform(inModes: [.common]) {
        NSApplication.shared.terminate(nil)
    }
}

extension String {
    func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(self, forType: .string)
    }
}

func - (a: CGPoint, b: CGPoint) -> CGPoint {
    CGPoint(x: a.x - b.x, y: a.y - b.y)
}

func + (a: CGPoint, b: CGPoint) -> CGPoint {
    CGPoint(x: a.x + b.x, y: a.y + b.y)
}

extension CGPoint: ConvenienceCopyable {}

extension CGPoint {
    func distance(toOuterFrame rect: Rect) -> CGFloat {
        // Subtract 1 from maxX/maxY because the right/bottom bounds are
        // exclusive.
        let dx = max(rect.minX - x, 0, x - (rect.maxX - 1))
        let dy = max(rect.minY - y, 0, y - (rect.maxY - 1))
        return CGPoint(x: dx, y: dy).vectorLength
    }

    func coerce(in rect: Rect) -> CGPoint? {
        guard let xRange = rect.minX.until(incl: rect.maxX - 1) else { return nil }
        guard let yRange = rect.minY.until(incl: rect.maxY - 1) else { return nil }
        return CGPoint(x: x.coerce(in: xRange), y: y.coerce(in: yRange))
    }

    func addingXOffset(_ offset: CGFloat) -> CGPoint { CGPoint(x: x + offset, y: y) }
    func addingYOffset(_ offset: CGFloat) -> CGPoint { CGPoint(x: x, y: y + offset) }
    func addingOffset(_ orientation: Orientation, _ offset: CGFloat) -> CGPoint { orientation == .h ? addingXOffset(offset) : addingYOffset(offset) }

    func getProjection(_ orientation: Orientation) -> Double { orientation == .h ? x : y }

    var vectorLength: CGFloat { sqrt(x * x + y * y) }

    var monitorApproximation: Monitor { monitors.minByOrDie { distance(toOuterFrame: $0.rect) } }
}

extension CGFloat {
    func div(_ denominator: Int) -> CGFloat? {
        denominator == 0 ? nil : self / CGFloat(denominator)
    }

    func coerce(in range: ClosedRange<CGFloat>) -> CGFloat {
        switch true {
            case self > range.upperBound: range.upperBound
            case self < range.lowerBound: range.lowerBound
            default: self
        }
    }
}

extension CGPoint: @retroactive Hashable { // todo migrate to self written Point
    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
}

#if DEBUG
    let isDebug = true
#else
    let isDebug = false
#endif

@inlinable
func checkCancellation() throws(CancellationError) {
    if Task.isCancelled {
        throw CancellationError()
    }
}
