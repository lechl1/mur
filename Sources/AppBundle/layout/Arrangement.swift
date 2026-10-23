import AppKit
import Common
import Foundation

/// mur — WHERE EACH WINDOW IS, AS RELATIVE POSITIONS.
///
/// A workspace is saved as an array of columns, each an array of window
/// identities, top to bottom. No lane or slot numbers: those are rewritten
/// by every compaction, and a window remembered as "lane 4" came back
/// wherever lane 4 happened to be. What survives is who it sat beside.
///
/// A window that closes stays in the array as a GHOST. When its app opens a
/// window again (an app restart, mur's own restart), it goes back beside
/// whichever of its old neighbours are still there — under the window that
/// was above it, or in a column of its own next to the column that was
/// beside it.
struct ArrangedWindow: Codable, Hashable {
    let appId: String
    /// Normalised (`normalizedSessionTitle`), so a terminal's status glyph
    /// doesn't make it a different window.
    // periphery:ignore - read through the synthesized Hashable/Codable
    // conformance: it is half of what tells two windows of an app apart.
    let title: String
    /// Terminals only: the cwd tells terminals with similar titles apart.
    var cwd: String?
}

struct ArrangedColumn: Codable, Equatable {
    var width: CGFloat
    var windows: [ArrangedWindow]
}

enum Arrangement {
    struct Path: Hashable {
        let column: Int
        let row: Int
    }

    static func paths(_ columns: [ArrangedColumn]) -> [Path] {
        columns.enumerated().flatMap { c, col in col.windows.indices.map { Path(column: c, row: $0) } }
    }

    /// Pair each live window (by index into `live`) with a saved entry:
    /// the same identity first, then an unclaimed entry of the same app —
    /// the window was renamed (a browser showing another tab), it is still
    /// that window.
    static func match(saved: [ArrangedColumn], live: [ArrangedWindow]) -> [Int: Path] {
        let all = paths(saved)
        var taken = Set<Path>()
        var out: [Int: Path] = [:]
        func entry(_ p: Path) -> ArrangedWindow { saved[p.column].windows[p.row] }
        for (i, w) in live.enumerated() {
            if let p = all.first(where: { !taken.contains($0) && entry($0) == w }) {
                out[i] = p
                taken.insert(p)
            }
        }
        for (i, w) in live.enumerated() where out[i] == nil {
            if let p = all.first(where: { !taken.contains($0) && entry($0).appId == w.appId }) {
                out[i] = p
                taken.insert(p)
            }
        }
        return out
    }

    /// The live arrangement, with every saved window that isn't live any
    /// more (a ghost) put back beside its old neighbours. `heldElsewhere`
    /// are windows live on another workspace: they moved, so they are no
    /// ghost here. Returns the columns and, per path, the index into the
    /// flattened `live` of the window there (ghosts have none).
    static func merge(
        saved: [ArrangedColumn],
        live: [ArrangedColumn],
        heldElsewhere: Set<ArrangedWindow> = [],
    ) -> (columns: [ArrangedColumn], liveAt: [Path: Int]) {
        let liveKeys = Set(live.flatMap(\.windows))
        let saved = saved
            .map { ArrangedColumn(width: $0.width, windows: $0.windows.filter { !heldElsewhere.contains($0) || liveKeys.contains($0) }) }
            .filter { !$0.windows.isEmpty }
        let flatLive = live.flatMap(\.windows)
        let matched = match(saved: saved, live: flatLive)
        struct Cell {
            let window: ArrangedWindow
            let from: Path?
            let liveIndex: Int?
        }
        var result: [(width: CGFloat, cells: [Cell])] = []
        var i = 0
        for col in live {
            var cells: [Cell] = []
            for w in col.windows {
                cells.append(Cell(window: w, from: matched[i], liveIndex: i))
                i += 1
            }
            result.append((col.width, cells))
        }
        let held = Set(matched.values)
        func locate(_ p: Path) -> (column: Int, row: Int)? {
            for (c, col) in result.enumerated() {
                if let r = col.cells.firstIndex(where: { $0.from == p }) { return (c, r) }
            }
            return nil
        }
        func locateColumn(_ c: Int) -> Int? {
            saved[c].windows.indices.lazy.compactMap { locate(Path(column: c, row: $0)) }.first?.column
        }
        for p in paths(saved) where !held.contains(p) {
            let col = saved[p.column]
            let ghost = Cell(window: col.windows[p.row], from: p, liveIndex: nil)
            if let a = (0 ..< p.row).reversed().lazy.compactMap({ locate(Path(column: p.column, row: $0)) }).first {
                result[a.column].cells.insert(ghost, at: a.row + 1)
            } else if let b = (p.row + 1 ..< col.windows.count).lazy.compactMap({ locate(Path(column: p.column, row: $0)) }).first {
                result[b.column].cells.insert(ghost, at: b.row)
            } else if let l = (0 ..< p.column).reversed().lazy.compactMap(locateColumn).first {
                result.insert((col.width, [ghost]), at: l + 1)
            } else if let r = (p.column + 1 ..< saved.count).lazy.compactMap(locateColumn).first {
                result.insert((col.width, [ghost]), at: r)
            } else {
                result.append((col.width, [ghost]))
            }
        }
        var liveAt: [Path: Int] = [:]
        for (c, col) in result.enumerated() {
            for (r, cell) in col.cells.enumerated() {
                if let li = cell.liveIndex { liveAt[Path(column: c, row: r)] = li }
            }
        }
        return (result.map { ArrangedColumn(width: $0.width, windows: $0.cells.map(\.window)) }, liveAt)
    }

    /// Where a newly opened window of `appId` goes: the first ghost of that
    /// app, described by the live windows around it (`windowAt` maps a path
    /// to the window there now, nil for a ghost).
    static func ghostCell(
        appId: String,
        in columns: [ArrangedColumn],
        windowAt: (Path) -> WindowId?,
    ) -> (path: Path, cell: StackingLayout.ParkedCell)? {
        guard let p = paths(columns).first(where: { windowAt($0) == nil && columns[$0.column].windows[$0.row].appId == appId })
        else { return nil }
        let rows = columns[p.column].windows.indices
        func column(_ c: Int) -> [WindowId] {
            columns[c].windows.indices.compactMap { windowAt(Path(column: c, row: $0)) }
        }
        let cell = StackingLayout.ParkedCell(
            above: rows.filter { $0 < p.row }.reversed().compactMap { windowAt(Path(column: p.column, row: $0)) },
            below: rows.filter { $0 > p.row }.compactMap { windowAt(Path(column: p.column, row: $0)) },
            left: (0 ..< p.column).reversed().map(column),
            right: (p.column + 1 ..< columns.count).map(column),
            laneWeight: columns[p.column].width,
            stripTotal: nil,
        )
        return (p, cell)
    }
}

/// Persisted to `~/.config/mur/arrangement.json`.
final class ArrangementStore {
    private(set) var workspaces: [String: [ArrangedColumn]] = [:]
    /// The window at each path, as of the last capture (or claim).
    private var liveIds: [String: [Arrangement.Path: WindowId]] = [:]
    /// Entries already handed to a window by the restore this run.
    private var claimed: Set<String> = []
    private let url: URL

    init(url: URL = ArrangementStore.defaultURL()) {
        self.url = url
        load()
    }

    static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mur/arrangement.json")
    }

    var entryCount: Int { workspaces.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.windows.count } } }

    /// Record the live layout. `ids` mirrors `live` (same shape). While
    /// `restoring`, the saved arrangement is the one being restored and
    /// must not be overwritten by a half-built screen: only learn which
    /// window is which entry.
    func update(live: [String: [ArrangedColumn]], ids: [String: [[WindowId]]], restoring: Bool) {
        for (ws, cols) in live {
            let flatIds = (ids[ws] ?? []).flatMap { $0 }
            let saved = workspaces[ws] ?? []
            var at: [Arrangement.Path: WindowId] = [:]
            if restoring {
                for (i, p) in Arrangement.match(saved: saved, live: cols.flatMap(\.windows)) where i < flatIds.count {
                    at[p] = flatIds[i]
                }
            } else {
                let elsewhere = Set(live.filter { $0.key != ws }.values.flatMap { $0.flatMap(\.windows) })
                let merged = Arrangement.merge(saved: saved, live: cols, heldElsewhere: elsewhere)
                workspaces[ws] = merged.columns
                for (p, i) in merged.liveAt where i < flatIds.count { at[p] = flatIds[i] }
            }
            liveIds[ws] = at
        }
        if !restoring {
            // A workspace with nothing open keeps its ghosts, minus windows
            // that are open somewhere else now.
            let allLive = Set(live.values.flatMap { $0.flatMap(\.windows) })
            for ws in workspaces.keys where live[ws] == nil {
                workspaces[ws] = Arrangement.merge(saved: workspaces[ws] ?? [], live: [], heldElsewhere: allLive).columns
                liveIds[ws] = [:]
            }
            save()
        }
    }

    /// The first ghost of `appId` on `workspace`, as a cell to place a new
    /// window in; marks it held by `windowId`.
    func takeGhostCell(appId: String, workspace: String, windowId: WindowId, isPlaced: (WindowId) -> Bool) -> StackingLayout.ParkedCell? {
        let ids = liveIds[workspace] ?? [:]
        guard let found = Arrangement.ghostCell(
            appId: appId,
            in: workspaces[workspace] ?? [],
            windowAt: { ids[$0].flatMap { isPlaced($0) ? $0 : nil } },
        ) else { return nil }
        liveIds[workspace, default: [:]][found.path] = windowId
        return found.cell
    }

    /// The restore's lookup: the saved entry for this window, across all
    /// workspaces (sorted, so it's stable). Same identity first; for a
    /// terminal the same cwd next; then any entry of the app (`isAppGuess`).
    /// Each entry is handed out once per run.
    func claim(_ w: ArrangedWindow) -> (workspace: String, path: Arrangement.Path, isAppGuess: Bool)? {
        let candidates = workspaces.keys.sorted().flatMap { ws in
            Arrangement.paths(workspaces[ws] ?? []).map { (ws, $0, workspaces[ws]![$0.column].windows[$0.row]) }
        }.filter { !claimed.contains(Self.claimKey($0.0, $0.1)) }
        let pick = candidates.first { $0.2 == w }.map { ($0, false) }
            ?? (w.cwd == nil ? nil : candidates.first { $0.2.appId == w.appId && $0.2.cwd == w.cwd }.map { ($0, false) })
            ?? candidates.first { $0.2.appId == w.appId }.map { ($0, true) }
        guard let ((ws, path, _), guess) = pick else { return nil }
        claimed.insert(Self.claimKey(ws, path))
        return (ws, path, guess)
    }

    private static func claimKey(_ ws: String, _ p: Arrangement.Path) -> String { "\(ws)|\(p.column)|\(p.row)" }

    private struct OnDisk: Codable {
        // periphery:ignore - the on-disk schema marker.
        var version = 1
        let workspaces: [String: [ArrangedColumn]]
    }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(OnDisk.self, from: data) else { return }
        workspaces = decoded.workspaces
    }

    func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(OnDisk(workspaces: workspaces)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

@MainActor let arrangementStore = ArrangementStore()

/// The identity mur saves a window under.
@MainActor
func arrangedWindow(_ window: Window) async -> ArrangedWindow {
    let appId = window.app.rawAppBundleId ?? ""
    let raw = (try? await window.title) ?? ""
    let cwd = sessionRestoreTerminalBundleIds.contains(appId) ? await resolveTerminalCwd(window) : nil
    return ArrangedWindow(appId: appId, title: normalizedSessionTitle(raw) ?? raw, cwd: cwd)
}

/// Save every workspace's columns as relative positions.
@MainActor
func captureArrangement() async {
    var live: [String: [ArrangedColumn]] = [:]
    var ids: [String: [[WindowId]]] = [:]
    for workspace in Workspace.all {
        let layout = workspace.stackingLayout
        var cols: [ArrangedColumn] = []
        var idCols: [[WindowId]] = []
        for lane in layout.usedLanes {
            var windows: [ArrangedWindow] = []
            var idCol: [WindowId] = []
            for id in layout.windows(in: lane) where layout.placements[id]?.lane0 == lane {
                guard let window = Window.get(byId: id) else { continue }
                windows.append(await arrangedWindow(window))
                idCol.append(id)
            }
            guard !windows.isEmpty else { continue }
            cols.append(ArrangedColumn(width: layout.laneWeight(lane: lane), windows: windows))
            idCols.append(idCol)
        }
        if !cols.isEmpty {
            live[workspace.name] = cols
            ids[workspace.name] = idCols
        }
    }
    arrangementStore.update(live: live, ids: ids, restoring: isRestoringWindowState)
}
