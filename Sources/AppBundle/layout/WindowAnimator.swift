import AppKit
import Common
import Foundation

/// mur — spring-driven window animation (naru feel).
///
/// Instead of the instant `setAxFrame` jump, windows glide to their target
/// rects with a **critically-damped spring** (mass 1, stiffness 800, ζ = 1 —
/// fast, no overshoot; the same parameters naru uses for view/resize
/// movement). Each animated quantity (x, y, width, height) is driven by the
/// closed-form critically-damped solution `to + e^(−β·t)·(x0 + β·x0·t)` with
/// `β = √stiffness` and start velocity 0.
///
/// **Feedback guard.** Every per-frame `setAxFrame` fires an AX
/// move/resize notification. The move/resize observers consult
/// `animatingIds` and ignore notifications for windows we're driving, so the
/// animation never triggers a refresh storm. A single refresh happens when a
/// window settles (its final frame leaves `animatingIds`).
@MainActor
final class WindowAnimator {
    static let shared = WindowAnimator()

    /// Master switch. Flip to `false` to fall back to instant placement if
    /// the AX-driven animation feels janky on a given setup.
    static let enabled = true

    /// Critically-damped spring, mass 1. `β = √stiffness = damping/2` for
    /// ζ = 1. Stiffness 800 settles in ~200 ms.
    private let stiffness: CGFloat = 800
    private var beta: CGFloat { sqrt(stiffness) }
    /// Settle tolerance in px — below this on every component the animation
    /// snaps to the target and stops.
    private let settleEps: CGFloat = 0.75
    /// Hard cap so a stuck animation can never run forever.
    private let maxDuration: TimeInterval = 1.0

    private struct Anim {
        var from: Rect
        var to: Rect
        var start: TimeInterval
    }
    private var anims: [WindowId: Anim] = [:]
    private var timer: Timer?

    /// Windows the animator is currently driving. The AX move/resize
    /// observers ignore notifications for these (see `resizedObs` /
    /// `movedObs`) so our own per-frame `setAxFrame`s don't cause refreshes.
    private(set) var animatingIds: Set<WindowId> = []

    private func now() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

    /// Animate `window` from `from` (its last applied rect) to `to`. If the
    /// window is already animating, it retargets from the current
    /// interpolated position (velocity reset — fine for a critically-damped
    /// spring). A negligible change collapses to an instant set.
    func animate(_ window: Window, from: Rect?, to: Rect) {
        let wid = window.windowId
        guard Self.enabled else {
            window.setAxFrame(to.topLeftCorner, to.size)
            return
        }
        let current: Rect
        if let a = anims[wid] {
            current = interpolate(a, at: now())
        } else if let from {
            current = from
        } else {
            // First placement, no prior rect → nothing to animate from.
            window.setAxFrame(to.topLeftCorner, to.size)
            return
        }
        if rectClose(current, to) {
            finish(wid, to: to, window: window)
            return
        }
        anims[wid] = Anim(from: current, to: to, start: now())
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

    private func finish(_ wid: WindowId, to: Rect, window: Window) {
        anims[wid] = nil
        animatingIds.remove(wid)
        window.setAxFrame(to.topLeftCorner, to.size)
    }

    private func springValue(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
        let x0 = from - to
        return to + exp(-beta * t) * (x0 + beta * x0 * t)
    }

    private func interpolate(_ a: Anim, at t0: TimeInterval) -> Rect {
        let t = CGFloat(max(0, t0 - a.start))
        return Rect(
            topLeftX: springValue(a.from.topLeftX, a.to.topLeftX, t),
            topLeftY: springValue(a.from.topLeftY, a.to.topLeftY, t),
            width: max(1, springValue(a.from.width, a.to.width, t)),
            height: max(1, springValue(a.from.height, a.to.height, t)),
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
        for (wid, a) in anims {
            guard let window = Window.get(byId: wid) else { cancel(wid); continue }
            let settledByTime = t0 - a.start >= maxDuration
            let r = interpolate(a, at: t0)
            if settledByTime || rectClose(r, a.to) {
                finish(wid, to: a.to, window: window)
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
