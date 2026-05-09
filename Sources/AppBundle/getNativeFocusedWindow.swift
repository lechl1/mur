import AppKit
import Common

@MainActor
var appForTests: (any AbstractApp)? = nil

@MainActor
private var focusedApp: (any AbstractApp)? {
    get async throws {
        if isUnitTest {
            return appForTests
        } else {
            check(appForTests == nil)
            return switch NSWorkspace.shared.frontmostApplication {
                case let frontmostApplication?: try await MacApp.getOrRegister(frontmostApplication)
                case nil: nil
            }
        }
    }
}

/// Thrown by `getNativeFocusedWindow` when the AX query for the
/// frontmost app's focused window doesn't return within the deadline.
/// Distinguishes "AX is slow" from "there really is no focused window"
/// so callers can fall back to the last-known focus instead of clobbering
/// the cache with nil.
struct FocusedWindowTimeoutError: Error {}

@MainActor
func getNativeFocusedWindow() async throws -> Window? {
    // mur — bound the focused-window AX query so that a slow app
    // (Chromium-based browsers, Godot, …) can't deadlock the main actor.
    // The query keeps running on the AX thread in the background; we
    // stop awaiting it past the deadline and let the caller decide what
    // to do with the timeout (typically: keep the previous focus cached,
    // don't overwrite with nil).
    return try await withFocusedWindowTimeout(nanoseconds: 1_500_000_000) {
        try await focusedApp?.getFocusedWindow()
    }
}

/// First-to-signal-wins race between an async operation and a sleep.
/// Returns the operation's value if it completes within the deadline,
/// otherwise throws `FocusedWindowTimeoutError`. The operation keeps
/// running in the background after timeout — it just no longer holds
/// the awaiter.
@MainActor
private func withFocusedWindowTimeout(
    nanoseconds: UInt64,
    operation: @MainActor @escaping () async throws -> Window?,
) async throws -> Window? {
    let guardBox = ResumeOnceGuard()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Window?, Error>) in
        Task { @MainActor in
            do {
                let w = try await operation()
                if guardBox.tryClaim() { cont.resume(returning: w) }
            } catch {
                if guardBox.tryClaim() { cont.resume(throwing: error) }
            }
        }
        // GCD timer: fires regardless of cooperative cancellation, so
        // even if the operation's await is wedged inside an AX call we
        // still resume the continuation.
        let delaySec = Double(nanoseconds) / 1_000_000_000
        DispatchQueue.global().asyncAfter(deadline: .now() + delaySec) {
            if guardBox.tryClaim() { cont.resume(throwing: FocusedWindowTimeoutError()) }
        }
    }
}

