import AppKit
import Common

/// mur — windows that hold a tile but can't be seen. Accessibility lists
/// them as ordinary windows, but the window server draws nothing: Dimify
/// keeps its closed "Dimify Settings" window around fully transparent and
/// 0×0, and a window AX still reports after it closed has no window-server
/// entry at all. Tiled, each one reserves an empty column.
///
/// Every full refresh asks the window server which windows are ghosts. A
/// ghost is parked out of the grid and left floating — not an explicit
/// float, so it's no entry in `explicitlyFloatingWindowIds` — and once it
/// is drawn again `tileWindowsNotExplicitlyFloating` tiles it, `unpark`
/// putting it back where it was.
@MainActor var ghostWindowIds: Set<WindowId> = []

/// Smaller than this on either side and nobody can see or use it.
private let ghostMaxSide: CGFloat = 10

/// A window the window server reports as transparent or (next to) no size.
func isGhostFrame(alpha: CGFloat, size: CGSize) -> Bool {
    alpha <= 0 || size.width < ghostMaxSide || size.height < ghostMaxSide
}

/// The window-server ids of `candidates` that are ghosts: drawn invisibly,
/// or missing from the window server altogether. Empty when the window
/// server can't be asked.
@MainActor
func windowServerGhostIds(among candidates: Set<WindowId>) -> Set<WindowId> {
    guard !candidates.isEmpty,
          let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
          !list.isEmpty
    else { return [] }
    var drawn: Set<WindowId> = []
    var ghosts: Set<WindowId> = []
    for info in list {
        guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, candidates.contains(id) else { continue }
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1
        let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        if isGhostFrame(alpha: alpha, size: bounds.size) { ghosts.insert(id) } else { drawn.insert(id) }
    }
    return ghosts.union(candidates.subtracting(drawn).subtracting(ghosts))
}

/// Park the ghosts among the windows in the workspaces' grids and forget
/// the ones that are drawn again. Runs in every full refresh, before
/// `tileWindowsNotExplicitlyFloating`.
@MainActor
func updateGhostWindows() {
    guard config.experimentalStackingLayout else { return }
    var candidates = ghostWindowIds
    for workspace in Workspace.all { candidates.formUnion(workspace.stackingLayout.placements.keys) }
    applyGhostWindows(windowServerGhostIds(among: candidates))
}

/// `updateGhostWindows` with the window server's answer given.
@MainActor
func applyGhostWindows(_ ghosts: Set<WindowId>) {
    ghostWindowIds = ghostWindowIds.intersection(ghosts)
    for workspace in Workspace.all {
        for windowId in Array(workspace.stackingLayout.placements.keys) where ghosts.contains(windowId) {
            guard let window = Window.get(byId: windowId), window.nodeWorkspace === workspace else { continue }
            workspace.stackingLayout.park(windowId)
            _ = window.bindAsFloatingWindow(to: workspace)
            ghostWindowIds.insert(windowId)
            fputs("mur: window \(windowId) (\(window.app.name ?? "?")) can't be seen; took it out of its tile\n", stderr)
        }
    }
}
