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
    let windowTitle: String
}

/// A remembered window mode: floating, or tiled at a span.
struct StoredWindowState: Equatable {
    var floating: Bool
    /// The window's tile. Ignored while `floating`; kept so an un-float can
    /// restore the previous tile.
    var span: TileSpan

    static func tiled(_ span: TileSpan) -> StoredWindowState { .init(floating: false, span: span) }
}

struct WindowMemoryEntry: Codable, Equatable {
    let shape: LayoutShape
    let lane0: Int
    let lane1: Int
    let slot0: Int
    let slot1: Int
    let floating: Bool

    init(shape: LayoutShape, state: StoredWindowState) {
        self.shape = shape
        self.lane0 = state.span.lane0
        self.lane1 = state.span.lane1
        self.slot0 = state.span.slot0
        self.slot1 = state.span.slot1
        self.floating = state.floating
    }

    var state: StoredWindowState {
        StoredWindowState(floating: floating, span: TileSpan(lane0: lane0, lane1: lane1, slot0: slot0, slot1: slot1))
    }

    // Codable migration:
    //  - v1 payloads encoded a single `lane` field → decode as lane0 == lane1.
    //  - pre-floating payloads have no `floating` field → default to false.
    enum CodingKeys: String, CodingKey {
        case shape, lane, lane0, lane1, slot0, slot1, floating
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shape, forKey: .shape)
        try c.encode(lane0, forKey: .lane0)
        try c.encode(lane1, forKey: .lane1)
        try c.encode(slot0, forKey: .slot0)
        try c.encode(slot1, forKey: .slot1)
        try c.encode(floating, forKey: .floating)
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

    // MARK: mutation

    /// Remember the window as TILED at `span`.
    func remember(appId: String, title: String, shape: LayoutShape, span: TileSpan) {
        let key = WindowMemoryKey(appId: appId, windowTitle: title)
        var byShape = entries[shape] ?? [:]
        byShape[key] = .tiled(span)
        entries[shape] = byShape
    }

    /// Remember the window as FLOATING, keeping any previously-remembered
    /// span so a later re-tile can return it to its old cell.
    func rememberFloating(appId: String, title: String, shape: LayoutShape) {
        let key = WindowMemoryKey(appId: appId, windowTitle: title)
        var byShape = entries[shape] ?? [:]
        let span = byShape[key]?.span ?? .soleSlot(lane: 0)
        byShape[key] = StoredWindowState(floating: true, span: span)
        entries[shape] = byShape
    }

    func forget(appId: String, title: String, shape: LayoutShape) {
        let key = WindowMemoryKey(appId: appId, windowTitle: title)
        entries[shape]?.removeValue(forKey: key)
        if entries[shape]?.isEmpty == true { entries.removeValue(forKey: shape) }
    }

    // MARK: persistence

    private struct OnDisk: Codable {
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
        let payload = OnDisk(version: 3, entries: flat)
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
