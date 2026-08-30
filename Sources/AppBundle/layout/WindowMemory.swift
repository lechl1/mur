import AppKit
import Common
import Foundation

/// Persistent per-window state store, keyed by (app bundle id, window title)
/// and `LayoutShape`. Records whether a window was **floating** or **tiled**
/// (and, when tiled, its `TileSpan`). On restart mur restores each window to
/// the same mode/position instead of re-running the placement heuristic.
///
/// The window TITLE is part of the key so multiple windows of the same app
/// (e.g. several browser windows) each restore to their own state. Keyed by
/// `LayoutShape` first so a workspace's landscape vs portrait memories don't
/// cross-contaminate when a monitor rotates.
///
/// Persisted to `~/.config/mur/window-memory.json`.
struct WindowMemoryKey: Hashable, Codable {
    let appId: String
    // periphery:ignore - read through the synthesized Hashable/Codable
    // conformance: the title is half of the key that tells two windows
    // of the same app apart.
    let windowTitle: String
}

/// A remembered window mode: floating, or tiled at a span, plus the
/// workspace it lived in. The `span` fixes its position relative to the
/// other windows in that workspace's grid.
struct StoredWindowState: Equatable {
    var floating: Bool
    /// The window's tile. Ignored while `floating`; kept so an un-float can
    /// restore the previous tile.
    var span: TileSpan
    /// Name of the workspace the window belonged to (empty = unknown).
    var workspace: String
}

struct WindowMemoryEntry: Codable, Equatable {
    let shape: LayoutShape
    let lane0: Int
    let lane1: Int
    let slot0: Int
    let slot1: Int
    let floating: Bool
    let workspace: String

    init(shape: LayoutShape, state: StoredWindowState) {
        self.shape = shape
        self.lane0 = state.span.lane0
        self.lane1 = state.span.lane1
        self.slot0 = state.span.slot0
        self.slot1 = state.span.slot1
        self.floating = state.floating
        self.workspace = state.workspace
    }

    var state: StoredWindowState {
        StoredWindowState(
            floating: floating,
            span: TileSpan(lane0: lane0, lane1: lane1, slot0: slot0, slot1: slot1),
            workspace: workspace,
        )
    }

    // Codable migration:
    //  - v1 payloads encoded a single `lane` field → decode as lane0 == lane1.
    //  - pre-floating payloads have no `floating` field → default to false.
    //  - pre-workspace payloads have no `workspace` field → default to "".
    enum CodingKeys: String, CodingKey {
        case shape, lane, lane0, lane1, slot0, slot1, floating, workspace
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.shape = try c.decode(LayoutShape.self, forKey: .shape)
        self.slot0 = try c.decode(Int.self, forKey: .slot0)
        self.slot1 = try c.decode(Int.self, forKey: .slot1)
        if let l0 = try c.decodeIfPresent(Int.self, forKey: .lane0),
           let l1 = try c.decodeIfPresent(Int.self, forKey: .lane1)
        {
            self.lane0 = l0
            self.lane1 = l1
        } else {
            let lane = try c.decode(Int.self, forKey: .lane)
            self.lane0 = lane
            self.lane1 = lane
        }
        self.floating = try c.decodeIfPresent(Bool.self, forKey: .floating) ?? false
        self.workspace = try c.decodeIfPresent(String.self, forKey: .workspace) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shape, forKey: .shape)
        try c.encode(lane0, forKey: .lane0)
        try c.encode(lane1, forKey: .lane1)
        try c.encode(slot0, forKey: .slot0)
        try c.encode(slot1, forKey: .slot1)
        try c.encode(floating, forKey: .floating)
        try c.encode(workspace, forKey: .workspace)
    }
}

final class WindowMemory {
    private var entries: [LayoutShape: [WindowMemoryKey: StoredWindowState]] = [:]
    private let storeURL: URL

    init(storeURL: URL = WindowMemory.defaultStoreURL()) {
        self.storeURL = storeURL
        load()
    }

    static func defaultStoreURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("mur", isDirectory: true)
            .appendingPathComponent("window-memory.json")
    }

    // MARK: lookup

    /// The remembered mode for this window, if any.
    func recall(appId: String, title: String, shape: LayoutShape) -> StoredWindowState? {
        entries[shape]?[WindowMemoryKey(appId: appId, windowTitle: title)]
    }

    /// mur — every TILED state remembered for `appId`, ordered by WORKSPACE
    /// first and then by cell (lane, then slot). Used as the fallback when
    /// the exact title misses: plenty of apps rewrite their title as you use
    /// them (a browser shows the current tab, a terminal shows the running
    /// command), so an exact-title-only memory forgets those windows on
    /// every restart and they land wherever the heuristic drops them.
    /// Handing this app's windows its remembered cells in order keeps their
    /// relative layout stable even when no single title matches.
    ///
    /// Ordering by workspace matters: sorting by cell alone interleaves the
    /// workspaces (every workspace has a lane 0), so N windows of one app
    /// spread over several workspaces got handed cells in an order that had
    /// nothing to do with where they came from. Workspace-major order fills
    /// one workspace's columns before moving to the next.
    func recallTiledByApp(appId: String, shape: LayoutShape) -> [StoredWindowState] {
        (entries[shape] ?? [:])
            .filter { $0.key.appId == appId && !$0.value.floating }
            .map(\.value)
            .sorted {
                ($0.workspace, $0.span.lane0, $0.span.slot0)
                    < ($1.workspace, $1.span.lane0, $1.span.slot0)
            }
    }

    /// How many TILED windows are remembered in total, across every shape.
    /// The restore uses it as the count of windows still to be steered: once
    /// that many have been claimed there is nothing left to restore, so
    /// restore mode can end before its deadline.
    func tiledEntryCount() -> Int {
        entries.values.reduce(0) { $0 + $1.values.count { !$0.floating } }
    }

    /// mur — the workspace this app's windows are remembered in, or `nil` if
    /// nothing is remembered for it. Ties (an app spread over several
    /// workspaces) break towards the workspace holding the most of its
    /// windows, then by name so the answer is stable across restarts.
    ///
    /// The restore needs this because macOS has no workspaces: at startup
    /// EVERY window is registered into whichever workspace happens to be
    /// active, so a window mur can't recognise (title rewritten, and its
    /// app's remembered cells already handed out) would otherwise stay
    /// there — the "windows jump back to the first workspace" symptom.
    /// Falling back to where the app lives keeps it off workspace 1.
    func dominantWorkspace(appId: String, shape: LayoutShape) -> String? {
        var counts: [String: Int] = [:]
        for (key, state) in entries[shape] ?? [:] where key.appId == appId && !state.workspace.isEmpty {
            counts[state.workspace, default: 0] += 1
        }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    // MARK: mutation

    /// Remember the window as TILED at `span` in `workspace`.
    func remember(appId: String, title: String, workspace: String, shape: LayoutShape, span: TileSpan) {
        let key = WindowMemoryKey(appId: appId, windowTitle: title)
        var byShape = entries[shape] ?? [:]
        byShape[key] = StoredWindowState(floating: false, span: span, workspace: workspace)
        entries[shape] = byShape
    }

    /// Remember the window as FLOATING in `workspace`, keeping any
    /// previously-remembered span so a later re-tile can return it to its
    /// old cell.
    func rememberFloating(appId: String, title: String, workspace: String, shape: LayoutShape) {
        let key = WindowMemoryKey(appId: appId, windowTitle: title)
        var byShape = entries[shape] ?? [:]
        let span = byShape[key]?.span ?? .soleSlot(lane: 0)
        byShape[key] = StoredWindowState(floating: true, span: span, workspace: workspace)
        entries[shape] = byShape
    }

    // MARK: persistence

    private struct OnDisk: Codable {
        // periphery:ignore - the on-disk schema marker. Write-only by
        // design: it exists so a future reader can tell versions apart.
        let version: Int
        let entries: [Keyed]
    }
    private struct Keyed: Codable {
        let key: WindowMemoryKey
        let entry: WindowMemoryEntry
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard let decoded = try? JSONDecoder().decode(OnDisk.self, from: data) else { return }
        var rebuilt: [LayoutShape: [WindowMemoryKey: StoredWindowState]] = [:]
        for keyed in decoded.entries {
            var byShape = rebuilt[keyed.entry.shape] ?? [:]
            byShape[keyed.key] = keyed.entry.state
            rebuilt[keyed.entry.shape] = byShape
        }
        entries = rebuilt
    }

    func save() {
        var flat: [Keyed] = []
        for (shape, byKey) in entries {
            for (key, state) in byKey {
                flat.append(Keyed(key: key, entry: WindowMemoryEntry(shape: shape, state: state)))
            }
        }
        let payload = OnDisk(version: 4, entries: flat)
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
