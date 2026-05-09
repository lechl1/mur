import AppKit
import SwiftUI

/// Floating mini-grid HUD shown when a window is moved or placed via
/// `mur grid-move` / `mur grid-place`. Renders a small `lanes × max(slots)`
/// grid with the focused window's span highlighted, then auto-dismisses
/// after a brief timeout.
///
/// Lifetime: a single global panel (`GridHud.shared`). Each call to
/// `update(...)` rebuilds the panel content and resets the dismiss timer.
@MainActor final class GridHud: NSPanelHud {
    static var shared: GridHud = GridHud()
    private var timer: Timer?
    private var panelFrame = NSRect(x: 0, y: 0, width: 220, height: 140)

    override init() {
        super.init()
    }

    func update(layout: GridLayout, span: TileSpan) {
        timer?.invalidate()
        contentView?.subviews.removeAll()
        // Snapshot the layout. We render at least one cell per lane so
        // empty lanes are still visible (collapsing them on screen would
        // hide the bloom-and-contract motion across empty columns).
        let slotsPerLane = (0..<layout.shape.lanes).map { lane in
            max(1, layout.slotCount(in: lane))
        }
        let snapshot = GridHudSnapshot(
            orientation: layout.shape.orientation,
            lanes: layout.shape.lanes,
            slotsPerLane: slotsPerLane,
            span: span,
        )
        let hostingView = NSHostingView(rootView: GridHudView(snapshot: snapshot))
        hostingView.frame = NSRect(x: 0, y: 0, width: panelFrame.width, height: panelFrame.height)
        contentView?.addSubview(hostingView)
        // Top-right of the main monitor with a small margin (Cocoa
        // coordinate origin is the bottom-left of the screen).
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
    let lanes: Int
    let slotsPerLane: [Int]
    let span: TileSpan
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
            laneStack.padding(10)
        }
        .frame(width: 220, height: 140)
    }

    @ViewBuilder
    private var laneStack: some View {
        // Landscape: lanes = columns → HStack of VStacks.
        // Portrait:  lanes = rows    → VStack of HStacks.
        switch snapshot.orientation {
            case .landscape:
                HStack(spacing: cellPad) {
                    ForEach(0..<snapshot.lanes, id: \.self) { lane in
                        slotStack(for: lane)
                    }
                }
            case .portrait:
                VStack(spacing: cellPad) {
                    ForEach(0..<snapshot.lanes, id: \.self) { lane in
                        slotStack(for: lane)
                    }
                }
        }
    }

    @ViewBuilder
    private func slotStack(for lane: Int) -> some View {
        let slots = snapshot.slotsPerLane[lane]
        switch snapshot.orientation {
            case .landscape:
                VStack(spacing: cellPad) {
                    ForEach(0..<slots, id: \.self) { slot in
                        cell(lane: lane, slot: slot)
                    }
                }
            case .portrait:
                HStack(spacing: cellPad) {
                    ForEach(0..<slots, id: \.self) { slot in
                        cell(lane: lane, slot: slot)
                    }
                }
        }
    }

    private func cell(lane: Int, slot: Int) -> some View {
        let isActive = snapshot.span.lane0 <= lane && lane <= snapshot.span.lane1
            && snapshot.span.slot0 <= slot && slot <= snapshot.span.slot1
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(isActive ? fillColor : emptyColor)
    }
}
