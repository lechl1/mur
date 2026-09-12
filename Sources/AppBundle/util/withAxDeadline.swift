import AppKit
import Common

/// Thrown by `withAxDeadline` when the operation doesn't finish in time.
struct AxDeadlineError: Error {}

/// mur — BOUND EVERY AX WAIT. First-to-signal-wins race between an async
/// operation and a timer: the operation's value if it lands inside the
/// deadline, otherwise `AxDeadlineError`. The operation keeps running in
/// the background — it just stops holding the awaiter.
///
/// This exists because an app can stop answering the Accessibility API
/// altogether while still being alive and `runningApplications`-listed.
/// An unbounded `await` on such an app doesn't fail, it never returns,
/// and any loop that waits for ALL apps stops there for good. Measured on
/// a live session: a wedged Preview held `refreshAllAndGetAliveWindowIds`
/// open forever, so no background refresh ever completed.
///
/// The timer is GCD, not `Task.sleep`: cooperative cancellation can't
/// reach an await wedged inside a synchronous AX call, but a dispatch
/// timer fires anyway.
@MainActor
func withAxDeadline<T>(
    nanoseconds: UInt64,
    operation: @MainActor @escaping () async throws -> T,
) async throws -> T {
    let guardBox = ResumeOnceGuard()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        Task { @MainActor in
            do {
                let value = try await operation()
                if guardBox.tryClaim() { cont.resume(returning: value) }
            } catch {
                if guardBox.tryClaim() { cont.resume(throwing: error) }
            }
        }
        let delaySec = Double(nanoseconds) / 1_000_000_000
        DispatchQueue.global().asyncAfter(deadline: .now() + delaySec) {
            if guardBox.tryClaim() { cont.resume(throwing: AxDeadlineError()) }
        }
    }
}
