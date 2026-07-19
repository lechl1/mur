import AppKit
import Common
import Foundation
import QuartzCore

/// mur — spring-driven window animation (naru feel).
///
/// The layout computes ALL target rects first, then hands the whole set to
/// `animateBatch(_:)`. Every window animates off a **single shared progress
/// clock** (a critically-damped spring, stiffness 800, ζ = 1 — fast, no
/// overshoot), interpolating `from → to` by the same fraction each frame. So
/// every window in one operation — the source and target windows / columns
/// of a move — starts and finishes **together, in lockstep**, rather than
/// each running its own distance-dependent spring (which read as animating
/// "one by one"). The spring is snappy (~130 ms settle); tune `stiffness`.
///
/// Because the batch captures each window's CURRENT on-screen position
/// before any window is moved, columns that swap positions animate past each
/// other correctly (neither jumps). **Retargeting mid-flight** — moving a
/// window while it's still animating — re-anchors the whole group to its
/// current positions and restarts the shared clock toward the new targets.
///
/// Timing is display-synced via `CADisplayLink` (macOS 14+, `Timer`
/// fallback) and redundant `setAxFrame`s (unchanged rounded pixels) are
/// skipped, to keep the AX-driven animation smooth.
///
/// **Feedback guard.** Every per-frame `setAxFrame` fires an AX
/// move/resize notification. The observers consult `isDrivingFrame(_:)` and
/// ignore notifications for windows we're driving, so the animation never
/// triggers a refresh storm.
@MainActor
final class WindowAnimator {
    static let shared = WindowAnimator()

    /// Master switch. Flip to `false` to fall back to instant placement if
    /// the AX-driven animation feels janky on a given setup.
    static let enabled = true

    /// Critically-damped spring, mass 1. `β = √stiffness = damping/2` for
    /// ζ = 1. Settle time scales as 1/√stiffness, so 1800 (≈2.25× the base
    /// 800) settles ~1.5× faster — roughly 130 ms.
    private let stiffness: CGFloat = 1800
    private var beta: CGFloat { sqrt(stiffness) }
    /// Settle tolerance in px — below this on every component a mover is
    /// treated as already at its target.
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
    /// Last integer-rounded rect pushed to each window, so we skip a
    /// `setAxFrame` when a frame's rounded pixels are unchanged (cuts
    /// main-thread AX work, especially on the slow tail / on 120 Hz).
    private var lastApplied: [WindowId: [Int]] = [:]
    /// Display-synced ticker (macOS 14+, type-erased to avoid an
    /// availability annotation on the stored property); `timer` is the
    /// macOS 13 fallback.
    private var displayLink: AnyObject?
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

    /// Single-window convenience — delegates to `animateBatch`.
    func animate(_ window: Window, from: Rect?, to: Rect) {
        animateBatch([(window: window, from: from, to: to)])
    }

    /// Animate a whole set of windows to their (already-computed) targets as
    /// one synchronized group. Current positions are captured up front, so a
    /// swap animates correctly and a fresh move retargets in-flight windows.
    func animateBatch(_ items: [(window: Window, from: Rect?, to: Rect)]) {
        guard Self.enabled else {
            for it in items { it.window.setAxFrame(it.to.topLeftCorner, it.to.size) }
            return
        }
        let t0 = now()
        let p = progress(elapsed(t0))

        // Capture every window's current position BEFORE moving any of them,
        // and split into no-op vs mover. Detect whether any target changed.
        var movers: [(wid: WindowId, window: Window, current: Rect, to: Rect)] = []
        var anyNewTarget = false
        for it in items {
            let wid = it.window.windowId
            let current: Rect
            if let a = anims[wid] {
                current = lerp(a.from, a.to, p)
            } else if let f = it.from {
                current = f
            } else {
                it.window.setAxFrame(it.to.topLeftCorner, it.to.size) // first placement
                continue
            }
            if rectClose(current, it.to) {
                finish(wid, to: it.to, window: it.window)
                continue
            }
            if anims[wid].map({ !rectClose($0.to, it.to) }) ?? true { anyNewTarget = true }
            movers.append((wid, it.window, current, it.to))
        }
        guard !movers.isEmpty else { return }

        if anyNewTarget {
            // Re-anchor every currently-animating window (incl. ones not in
            // this batch) to its current position, then restart the shared
            // clock so the whole group moves together from now.
            for (id, a) in anims { anims[id] = Anim(from: lerp(a.from, a.to, p), to: a.to) }
            sharedStart = t0
            for m in movers {
                anims[m.wid] = Anim(from: m.current, to: m.to)
                animatingIds.insert(m.wid)
            }
        } else {
            for m in movers where anims[m.wid] == nil {
                anims[m.wid] = Anim(from: m.current, to: m.to)
                animatingIds.insert(m.wid)
            }
        }

        // First frame (clock ~just reset → progress ≈ 0 → current positions).
        let p0 = progress(elapsed(now()))
        for m in movers where anims[m.wid] != nil {
            applyFrame(m.window, m.wid, lerp(anims[m.wid]!.from, anims[m.wid]!.to, p0))
        }
        startTicker()
    }

    /// Stop driving `wid` (e.g. the user grabbed it with the mouse). Leaves
    /// the window wherever it currently is.
    func cancel(_ wid: WindowId) {
        anims[wid] = nil
        animatingIds.remove(wid)
        lastApplied[wid] = nil
    }

    /// Whether the animator is ACTIVELY driving `wid`'s frame right now. The
    /// AX observers / auto-fit pre-pass use this to ignore the notifications
    /// caused by our own `setAxFrame`. SELF-HEALS a stale `animatingIds`
    /// entry (no live anim, or the shared clock has run past `maxDuration`)
    /// so a missed cleanup can't swallow a window's events until restart.
    func isDrivingFrame(_ wid: WindowId) -> Bool {
        guard animatingIds.contains(wid) else { return false }
        guard anims[wid] != nil, elapsed(now()) < CGFloat(maxDuration) else {
            anims[wid] = nil
            animatingIds.remove(wid)
            return false
        }
        return true
    }

    private func finish(_ wid: WindowId, to: Rect, window: Window) {
        anims[wid] = nil
        animatingIds.remove(wid)
        lastApplied[wid] = nil
        window.setAxFrame(to.topLeftCorner, to.size)
    }

    /// Push a frame, skipping the AX call when the integer-rounded rect is
    /// unchanged from the last frame we applied for this window.
    private func applyFrame(_ window: Window, _ wid: WindowId, _ r: Rect) {
        let rounded = [Int(r.topLeftX.rounded()), Int(r.topLeftY.rounded()),
                       Int(r.width.rounded()), Int(r.height.rounded())]
        if lastApplied[wid] == rounded { return }
        lastApplied[wid] = rounded
        window.setAxFrame(r.topLeftCorner, r.size)
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

    private func startTicker() {
        if displayLink != nil || timer != nil { return }
        if #available(macOS 14.0, *), let screen = NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(onDisplayTick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    @objc private func onDisplayTick() { tick() }

    private func stopTicker() {
        if #available(macOS 14.0, *) { (displayLink as? CADisplayLink)?.invalidate() }
        displayLink = nil
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let e = elapsed(now())
        let p = progress(e)
        let batchDone = e >= CGFloat(maxDuration) || p >= 1 - 1e-3
        for (wid, a) in Array(anims) {
            guard let window = Window.get(byId: wid) else { cancel(wid); continue }
            if batchDone {
                finish(wid, to: a.to, window: window)
            } else {
                applyFrame(window, wid, lerp(a.from, a.to, p))
            }
        }
        if anims.isEmpty { stopTicker() }
    }
}
