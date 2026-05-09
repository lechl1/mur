import AppKit
import SwiftUI

/// Floating mini-grid HUD shown when a window is moved or placed via
/// `mur grid-move` / `mur grid-place`. Mirrors the on-screen layout
/// faithfully:
///   - empty lanes are collapsed (only used lanes appear);
///   - each lane's width is proportional to its `laneWeight`;
///   - each cell's secondary-axis size is proportional to its slot weight.
///
/// The currently focused span is highlighted. Auto-dismisses 1.5s after
/// the last `update(...)`.
@MainActor final class GridHud: NSPanelHud {
    static var shared: GridHud = GridHud()
    private var timer: Timer?
    private var panelFrame = NSRect(x: 0, y: 0, width: 220, height: 140)

    override init() {
        super.init()
    }

    func update(layout: GridLayout, span: TileSpan, hoverSpan: TileSpan? = nil) {
        timer?.invalidate()
        contentView?.subviews.removeAll()
        let used = layout.usedLanes
        let laneWeights = used.map { layout.laneWeight(lane: $0) }
        let slotsPerLane = used.map { max(1, layout.slotCount(in: $0)) }
        let slotWeights = zip(used, slotsPerLane).map { lane, slots in
            (0..<slots).map { layout.slotWeight(lane: lane, slot: $0) }
        }
        // Per-cell window count: number of placements covering each
        // (lane, slot). 0 = empty (only ever happens for lanes with no
        // placements at all, since usedLanes filters those out), 1 =
        // single occupant, 2+ = overlapping windows.
        let cellCounts: [[Int]] = zip(used, slotsPerLane).map { lane, slots in
            (0..<slots).map { slot in
                layout.placements.values.reduce(0) { acc, p in
                    acc + (p.lane0 <= lane && lane <= p.lane1
                        && p.slot0 <= slot && slot <= p.slot1 ? 1 : 0)
                }
            }
        }
        let snapshot = GridHudSnapshot(
            orientation: layout.shape.orientation,
            usedLanes: used,
            laneWeights: laneWeights,
            slotsPerLane: slotsPerLane,
            slotWeights: slotWeights,
            span: span,
            hoverSpan: hoverSpan,
            cellCounts: cellCounts,
        )
        let hostingView = NSHostingView(rootView: GridHudView(snapshot: snapshot))
        hostingView.frame = NSRect(x: 0, y: 0, width: panelFrame.width, height: panelFrame.height)
        contentView?.addSubview(hostingView)
        panelFrame.origin.x = mainMonitor.width - panelFrame.size.width - 20
        panelFrame.origin.y = mainMonitor.height - panelFrame.size.height - 60
        setFrame(panelFrame, display: true)
        orderFrontRegardless()
        startTimer()
    }

    private func startTimer() {
        timer = .scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            Task { @MainActor [weak self] in
                self?.close()
            }
        }
    }
}

struct GridHudSnapshot {
    let orientation: LayoutOrientation
    /// Used lane indices (sorted ascending). Maps HUD column position →
    /// real lane index (so span hit-tests use the right value).
    let usedLanes: [Int]
    /// Parallel to `usedLanes`. Lane-axis weight per lane.
    let laneWeights: [CGFloat]
    /// Parallel to `usedLanes`. ≥ 1.
    let slotsPerLane: [Int]
    /// Parallel to `usedLanes`. Slot weights for that lane (length matches
    /// `slotsPerLane`).
    let slotWeights: [[CGFloat]]
    let span: TileSpan
    /// Optional drop-target preview shown during a drag-and-drop. Drawn
    /// with a distinct accent color so the user knows where the window
    /// will land if they release the mouse.
    let hoverSpan: TileSpan?
    /// Window count per visible cell. Parallel to `usedLanes` then
    /// per-lane slot index.
    let cellCounts: [[Int]]
}

struct GridHudView: View {
    let snapshot: GridHudSnapshot

    @Environment(\.colorScheme) var colorScheme: ColorScheme
    private var fillColor: Color { colorScheme == .dark ? .white : .black }
    private var emptyColor: Color { Color.gray.opacity(0.25) }
    private let cellPad: CGFloat = 3
    private let cornerRadius: CGFloat = 4

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
            GeometryReader { geo in
                laneStack(in: geo.size)
            }
            .padding(10)
        }
        .frame(width: 220, height: 140)
    }

    // The HUD mirrors the on-screen layout's proportions: lanes are
    // sized by their `laneWeight` share of the total used-lane weight,
    // slots within a lane by their `slotWeight` share. A soft minimum
    // size floor keeps very-shrunk tiles visible (and lets them
    // visually grow back proportionally as the user re-grows them);
    // the floor only kicks in for tiles below the floor, and the
    // remaining tiles scale to fill the rest of the bounds — so the
    // HUD always fills the panel.
    private static let minCellSize: CGFloat = 12

    @ViewBuilder
    private func laneStack(in size: CGSize) -> some View {
        let n = snapshot.usedLanes.count
        let mainAxis: CGFloat = snapshot.orientation == .landscape ? size.width : size.height
        let usableMain = mainAxis - CGFloat(max(0, n - 1)) * cellPad
        let laneSizes = Self.proportionalSizes(
            weights: snapshot.laneWeights, total: usableMain
        )

        switch snapshot.orientation {
            case .landscape:
                HStack(spacing: cellPad) {
                    ForEach(0..<n, id: \.self) { i in
                        slotStack(at: i)
                            .frame(width: laneSizes[i], height: size.height)
                    }
                }
            case .portrait:
                VStack(spacing: cellPad) {
                    ForEach(0..<n, id: \.self) { i in
                        slotStack(at: i)
                            .frame(width: size.width, height: laneSizes[i])
                    }
                }
        }
    }

    @ViewBuilder
    private func slotStack(at idx: Int) -> some View {
        let lane = snapshot.usedLanes[idx]
        let slots = snapshot.slotsPerLane[idx]
        let weights = snapshot.slotWeights[idx]
        GeometryReader { laneGeo in
            switch snapshot.orientation {
                case .landscape:
                    let usable = laneGeo.size.height - CGFloat(max(0, slots - 1)) * cellPad
                    let slotSizes = Self.proportionalSizes(weights: weights, total: usable)
                    VStack(spacing: cellPad) {
                        ForEach(0..<slots, id: \.self) { slot in
                            cell(lane: lane, slot: slot, laneIdx: idx)
                                .frame(width: laneGeo.size.width, height: slotSizes[slot])
                        }
                    }
                case .portrait:
                    let usable = laneGeo.size.width - CGFloat(max(0, slots - 1)) * cellPad
                    let slotSizes = Self.proportionalSizes(weights: weights, total: usable)
                    HStack(spacing: cellPad) {
                        ForEach(0..<slots, id: \.self) { slot in
                            cell(lane: lane, slot: slot, laneIdx: idx)
                                .frame(width: slotSizes[slot], height: laneGeo.size.height)
                        }
                    }
            }
        }
    }

    /// Distribute `total` over `weights.count` cells proportionally to
    /// `weights`, with a soft `minCellSize` floor: any cell whose
    /// proportional share is below the floor is bumped up to the
    /// floor, and the cells above the floor scale down to absorb the
    /// extra. Always sums to `total` (within fp rounding) so the HUD
    /// fills its bounds.
    static func proportionalSizes(weights: [CGFloat], total: CGFloat) -> [CGFloat] {
        let n = weights.count
        guard n > 0, total > 0 else { return Array(repeating: 0, count: n) }
        let totalWeight = max(0.0001, weights.reduce(0, +))
        let raw = weights.map { total * $0 / totalWeight }
        let floor = min(minCellSize, total / CGFloat(n))
        // Iteratively pin cells below the floor and rescale the rest;
        // converges in one pass for typical shrunken layouts.
        var sizes = raw
        var pinned: [Bool] = Array(repeating: false, count: n)
        while true {
            var newlyPinned = false
            let pinnedSum = (0..<n).reduce(0.0) { $0 + (pinned[$1] ? sizes[$1] : 0) }
            let remaining = total - pinnedSum
            let unpinnedWeightSum = (0..<n).reduce(0.0) { $0 + (pinned[$1] ? 0 : weights[$1]) }
            guard unpinnedWeightSum > 0 else { break }
            for i in 0..<n where !pinned[i] {
                let s = remaining * weights[i] / unpinnedWeightSum
                if s < floor {
                    sizes[i] = floor
                    pinned[i] = true
                    newlyPinned = true
                } else {
                    sizes[i] = s
                }
            }
            if !newlyPinned { break }
        }
        return sizes
    }

    private func cell(lane: Int, slot: Int, laneIdx: Int) -> some View {
        let isActive = snapshot.span.lane0 <= lane && lane <= snapshot.span.lane1
            && snapshot.span.slot0 <= slot && slot <= snapshot.span.slot1
        let isHover = snapshot.hoverSpan.map { h in
            h.lane0 <= lane && lane <= h.lane1 && h.slot0 <= slot && slot <= h.slot1
        } ?? false
        let count = (laneIdx >= 0 && laneIdx < snapshot.cellCounts.count
            && slot < snapshot.cellCounts[laneIdx].count)
            ? snapshot.cellCounts[laneIdx][slot] : 0
        let countColor = isActive ? (colorScheme == .dark ? Color.black : Color.white) : fillColor
        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isActive ? fillColor : emptyColor)
            if isHover {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(countColor)
            }
        }
    }
}
