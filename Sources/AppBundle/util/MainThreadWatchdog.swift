import Common
import Foundation
import os

/// mur — crash on purpose when the main thread stops answering, so launchd
/// restarts mur instead of leaving it wedged.
///
/// Crash protection (`install-service.sh`, `KeepAlive.SuccessfulExit =
/// false`) only helps when the process EXITS. A mur whose main thread is
/// stuck — a deadlock, an unbounded wait on a wedged app — keeps running
/// with every hotkey dead, which reads as "mur just stopped" and nothing
/// ever restarts it. The main queue ticks a heartbeat every second; a
/// background queue checks it, and if the main thread has been silent for
/// `mainThreadStallLimit` it aborts, which writes a crash report (with the
/// stuck main-thread stack) and hands the restart to launchd.
///
/// `DispatchTime` is uptime-based and pauses while the Mac sleeps, so a
/// long sleep doesn't look like a stall on wake.
private let mainThreadStallLimit: TimeInterval = 30
private let lastMainThreadBeat = OSAllocatedUnfairLock(initialState: DispatchTime.now())
@MainActor private var watchdogTimers: [DispatchSourceTimer] = []

@MainActor
func startMainThreadWatchdog() {
    guard watchdogTimers.isEmpty else { return }
    let beat = DispatchSource.makeTimerSource(queue: .main)
    beat.schedule(deadline: .now(), repeating: 1)
    beat.setEventHandler { lastMainThreadBeat.withLock { $0 = .now() } }

    let check = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    check.schedule(deadline: .now() + mainThreadStallLimit, repeating: 5)
    check.setEventHandler {
        let last = lastMainThreadBeat.withLock { $0 }
        let silent = Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1e9
        guard silent > mainThreadStallLimit else { return }
        FileHandle.standardError.write(Data(
            "mur: main thread unresponsive for \(Int(silent))s — aborting so launchd restarts mur\n".utf8,
        ))
        abort()
    }
    beat.resume()
    check.resume()
    watchdogTimers = [beat, check]
}
