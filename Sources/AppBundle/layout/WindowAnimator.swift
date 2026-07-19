import AppKit
import Common
import Foundation

/// mur — spring-driven window animation (naru feel).
///
/// Instead of the instant `setAxFrame` jump, windows glide to their target
/// rects. All windows animate off a **single shared progress clock** (a
/// critically-damped spring, stiffness 800, ζ = 1 — fast, no overshoot),
/// interpolating `from → to` by the same fraction every frame. So every
/// window involved in one operation — the source and target windows /
/// columns of a move — starts and finishes **together, in lockstep**,
/// rather than each running its own distance-dependent spring (which read
/// as windows animating "one by one").
///
/// Retargeting mid-flight re-anchors every animating window to its current
/// position and restarts the shared clock, so a new move sweeps the whole
/// group into one synchronized animation.
///
/// **Feedback guard.** Every per-frame `setAxFrame` fires an AX
/// move/resize notification. The observers consult `isDrivingFrame(_:)` and
/// ignore notifications for windows we're driving, so the animation never
/// triggers a refresh storm. A single refresh happens when a batch settles.
@MainActor
final class WindowAnimator {
    static let shared = WindowAnimator()

    /// Master switch. Flip to `false` to fall back to instant placement if
    /// the AX-driven animation feels janky on a given setup.
    static let enabled = true

    /// Critically-damped spring, mass 1. `β = √stiffness = damping/2` for
    /// ζ = 1. Stiffness 800 settles the shared progress in ~200 ms.
    private let stiffness: CGFloat = 800
    private var beta: CGFloat { sqrt(stiffness) }
    /// Settle tolerance in px — below this on every component a window is
    /// snapped to its target.
    private let settleEps: CGFloat = 0.75
    /// Hard cap so a stuck animation can never run forever.
    private let maxDuration: TimeInterval = 1.0

    private struct Anim {
        var from: Rect
        var to: Rect
    }
    private var anims: [WindowId: Anim] = [:]
    /// Start time of the shared progress clock — one for the whole group.
    private var sharedStart: TimeInterval = 0
    private var timer: Timer?

    /// Windows the animator is currently driving. The AX move/resize
    /// observers ignore notifications for these (via `isDrivingFrame`) so
    /// our own per-frame `setAxFrame`s don't cause refreshes.
    private(set) var animatingIds: Set<WindowId> = []

    private func now() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

    /// Shared progress 0 → 1 for `t` seconds since `sharedStart`, following a
    /// critically-damped spring settling (monotonic, no overshoot).
    private func progress(_ t: CGFloat) -> CGFloat {
        guard t > 0 else { return 0 }
        return 1 - exp(-beta * t) * (1 + beta * t)
    }

    private func elapsed(_ t0: TimeInterval) -> CGFloat { CGFloat(max(0, t0 - sharedStart)) }

    /// Animate `window` from `from` (its last applied rect) to `to`. If the
    /// window is already animating, it retargets from its current
    /// interpolated position. A negligible change collapses to an instant
    /// set. When the target actually changes, the whole animating group is
    /// re-anchored and the shared clock restarts so everything moves as one.
    func animate(_ window: Window, from: Rect?, to: Rect) {
        let wid = window.windowId
        guard Self.enabled else {
            window.setAxFrame(to.topLeftCorner, to.size)
            return
        }
        let t0 = now()
        let p = progress(elapsed(t0))
        let current: Rect
        if let a = anims[wid] {
            current = lerp(a.from, a.to, p)
        } else if let from {
            current = from
        } else {
            // First placement, no prior rect → nothing to animate from.
            window.setAxFrame(to.topLeftCorner, to.size)
            return
        }
        if rectClose(current, to) {
            anims[wid] = nil
            animatingIds.remove(wid)
            window.setAxFrame(to.topLeftCorner, to.size)
            return
        }
        let isNewTarget = anims[wid].map { !rectClose($0.to, to) } ?? true
        if isNewTarget {
            // Re-anchor every animating window to its current on-screen
            // position and restart the shared clock, so this move's windows
            // (and any still-settling ones) animate as one group.
            for (id, a) in anims { anims[id] = Anim(from: lerp(a.from, a.to, p), to: a.to) }
            sharedStart = t0
            anims[wid] = Anim(from: current, to: to)
        }
        animatingIds.insert(wid)
        window.setAxFrame(current.topLeftCorner, current.size)
        startTimer()
    }

    /// Stop driving `wid` (e.g. the user grabbed it with the mouse). Leaves
    /// the window wherever it currently is.
    func cancel(_ wid: WindowId) {
        anims[wid] = nil
        animatingIds.remove(wid)
    }

    /// Whether the animator is ACTIVELY driving `wid`'s frame right now. The
    /// AX move/resize observers and the auto-fit pre-pass call this to
    /// ignore the notifications caused by our own per-frame `setAxFrame`.
    ///
    /// SELF-HEALS: if `wid` lingers in `animatingIds` without a live
    /// animation (its `Anim` is gone, or the shared clock has run past
    /// `maxDuration`), the stale entry is pruned and `false` returned. Without
    /// this, one missed cleanup would make the observers swallow that
    /// window's resize/move events forever — "resize stops working until I
    /// restart mur".
    func isDrivingFrame(_ wid: WindowId) -> Bool {
        guard animatingIds.contains(wid) else { return false }
        guard anims[wid] != nil, elapsed(now()) < CGFloat(maxDuration) else {
            anims[wid] = nil
            animatingIds.remove(wid)
            return false
        }
        return true
    }

    private func lerp(_ a: Rect, _ b: Rect, _ p: CGFloat) -> Rect {
        Rect(
            topLeftX: a.topLeftX + (b.topLeftX - a.topLeftX) * p,
            topLeftY: a.topLeftY + (b.topLeftY - a.topLeftY) * p,
            width: max(1, a.width + (b.width - a.width) * p),
            height: max(1, a.height + (b.height - a.height) * p),
        )
    }

    private func rectClose(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.topLeftX - b.topLeftX) < settleEps &&
            abs(a.topLeftY - b.topLeftY) < settleEps &&
            abs(a.width - b.width) < settleEps &&
            abs(a.height - b.height) < settleEps
    }

    private func startTimer() {
        if timer != nil { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let t0 = now()
        let e = elapsed(t0)
        let p = progress(e)
        // One shared progress → all windows advance together and settle in
        // the same frame.
        let batchDone = e >= CGFloat(maxDuration) || p >= 1 - 1e-3
        for (wid, a) in Array(anims) {
            guard let window = Window.get(byId: wid) else { cancel(wid); continue }
            let r = lerp(a.from, a.to, p)
            if batchDone || rectClose(r, a.to) {
                window.setAxFrame(a.to.topLeftCorner, a.to.size)
                anims[wid] = nil
                animatingIds.remove(wid)
            } else {
                window.setAxFrame(r.topLeftCorner, r.size)
            }
        }
        if anims.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}
