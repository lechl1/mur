import AppKit
import Common

/// mur — a window that keeps its aspect ratio sets its height from the width
/// it's given: `height = slope * width + offset` (VLC: the video's ratio,
/// plus its toolbar as the offset). Handed a cell, it keeps the cell's width
/// and grows taller than the cell — past the bottom of the screen when the
/// column is wide. Such a window is laid out as wide as fits its cell's
/// height instead (`aspectFit`).
struct AspectLock: Equatable {
    let slope: CGFloat
    let offset: CGFloat

    /// The line through two measured sizes; nil unless height grows with width.
    init?(_ a: CGSize, _ b: CGSize) {
        guard abs(a.width - b.width) >= 1 else { return nil }
        let slope = (a.height - b.height) / (a.width - b.width)
        guard slope > 0 else { return nil }
        self.slope = slope
        self.offset = a.height - slope * a.width
    }

    func width(forHeight height: CGFloat) -> CGFloat { (height - offset) / slope }
}

/// Learned by the fill check (`learnAspectLock`), forgotten when the window closes.
@MainActor var aspectLocks: [WindowId: AspectLock] = [:]

/// The part of `cell` an aspect-locked window fills: the full height, as
/// wide as that allows, centred. Never narrower than the window's own
/// `minimumWidth` (it won't go below it, and would stick out of the cell
/// off-centre). A cell it fits already is returned as is.
func aspectFit(_ cell: Rect, lock: AspectLock?, minimumWidth: CGFloat = 0) -> Rect {
    guard let lock else { return cell }
    let width = max(lock.width(forHeight: cell.height).rounded(.down), minimumWidth)
    guard width > 0, width < cell.width else { return cell }
    return Rect(topLeftX: cell.topLeftX + ((cell.width - width) / 2).rounded(.down), topLeftY: cell.topLeftY, width: width, height: cell.height)
}

/// `window` was given `target` and settled at `tall`, taller than the cell.
/// That is either an aspect lock or a minimum height. Ask for the width the
/// target's height would allow if the whole window kept its proportions: an
/// aspect-locked window's height follows the width (at that width, or
/// clamped to its own minimum width) and the line through the two sizes is
/// learned; a minimum height doesn't move. True when one was learned.
@MainActor
func learnAspectLock(_ window: Window, target: Rect, tall: Rect, tolerance: CGFloat) async -> Bool {
    let probeWidth = (tall.width * target.height / tall.height).rounded(.down)
    window.setAxFrame(
        CGPoint(x: target.topLeftX + ((target.width - probeWidth) / 2).rounded(.down), y: target.topLeftY),
        CGSize(width: probeWidth, height: target.height),
    )
    try? await Task.sleep(nanoseconds: 350_000_000)
    // Taking the probe exactly is just a window catching up, not a lock.
    guard let again = try? await window.getAxRect(),
          abs(again.height - target.height) > tolerance || abs(again.width - probeWidth) > tolerance,
          let lock = AspectLock(tall.size, again.size) else { return false }
    aspectLocks[window.windowId] = lock
    eprint("mur: window \(window.windowId) keeps its aspect: height = \(lock.slope) * width + \(lock.offset)")
    return true
}
