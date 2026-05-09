import Foundation

/// One-shot atomic latch used to gate `CheckedContinuation.resume(...)`
/// calls when racing two completion paths (typically the actual async
/// operation and a GCD-timer-based timeout). The first caller to win
/// `tryClaim()` is responsible for resuming the continuation; every
/// subsequent caller no-ops.
///
/// Centralised here so both `MacApp` and `getNativeFocusedWindow` can
/// use the same primitive.
final class ResumeOnceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Atomically transition `done` from false → true. Returns true on
    /// the first call, false on every subsequent call.
    func tryClaim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
