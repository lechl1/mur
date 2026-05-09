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
        let snapshot = GridHudSnapshot(
            orientation: layout.shape.orientation,
            usedLanes: used,
            laneWeights: laneWeights,
            slotsPerLane: slotsPerLane,
            slotWeights: slotWeights,
            span: span,
            hoverSpan: hoverSpan,
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

    @ViewBuilder
    private func laneStack(in size: CGSize) -> some View {
        let n = snapshot.usedLanes.count
        let totalLaneWeight = max(0.0001, snapshot.laneWeights.reduce(0, +))
        let mainAxis: CGFloat = snapshot.orientation == .landscape ? size.width : size.height
        let usableMain = mainAxis - CGFloat(max(0, n - 1)) * cellPad

        switch snapshot.orientation {
            case .landscape:
                HStack(spacing: cellPad) {
                    ForEach(0..<n, id: \.self) { i in
                        slotStack(at: i)
                            .frame(
                                width: snapshot.laneWeights[i] / totalLaneWeight * usableMain,
                                height: size.height,
                            )
                    }
                }
            case .portrait:
                VStack(spacing: cellPad) {
                    ForEach(0..<n, id: \.self) { i in
                        slotStack(at: i)
                            .frame(
                                width: size.width,
                                height: snapshot.laneWeights[i] / totalLaneWeight * usableMain,
                            )
                    }
                }
        }
    }

    @ViewBuilder
    private func slotStack(at idx: Int) -> some View {
        let lane = snapshot.usedLanes[idx]
        let slots = snapshot.slotsPerLane[idx]
        let weights = snapshot.slotWeights[idx]
        let totalSlotWeight = max(0.0001, weights.reduce(0, +))
        GeometryReader { laneGeo in
            switch snapshot.orientation {
                case .landscape:
                    let usable = laneGeo.size.height - CGFloat(max(0, slots - 1)) * cellPad
                    VStack(spacing: cellPad) {
                        ForEach(0..<slots, id: \.self) { slot in
                            cell(lane: lane, slot: slot)
                                .frame(
                                    width: laneGeo.size.width,
                                    height: weights[slot] / totalSlotWeight * usable,
                                )
                        }
                    }
                case .portrait:
                    let usable = laneGeo.size.width - CGFloat(max(0, slots - 1)) * cellPad
                    HStack(spacing: cellPad) {
                        ForEach(0..<slots, id: \.self) { slot in
                            cell(lane: lane, slot: slot)
                                .frame(
                                    width: weights[slot] / totalSlotWeight * usable,
                                    height: laneGeo.size.height,
                                )
                        }
                    }
            }
        }
    }

    private func cell(lane: Int, slot: Int) -> some View {
        let isActive = snapshot.span.lane0 <= lane && lane <= snapshot.span.lane1
            && snapshot.span.slot0 <= slot && slot <= snapshot.span.slot1
        let isHover = snapshot.hoverSpan.map { h in
            h.lane0 <= lane && lane <= h.lane1 && h.slot0 <= slot && slot <= h.slot1
        } ?? false
        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isActive ? fillColor : emptyColor)
            if isHover {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }
}
