import AppKit
import Common
import Foundation

/// Per (app bundle id, window title) memory of the last `TileSpan` the user
/// placed a window in. When a matching window opens later, mur restores the
/// span instead of running the placement heuristic.
///
/// Keyed by `LayoutShape` first, so a workspace's landscape vs portrait
/// memories don't cross-contaminate when a monitor rotates.
///
/// Persisted to `~/.config/mur/window-memory.json`.
struct WindowMemoryKey: Hashable, Codable {
    let appId: String
    let windowTitle: String
}

struct WindowMemoryEntry: Codable, Equatable {
    let shape: LayoutShape
    let lane0: Int
    let lane1: Int
    let slot0: Int
    let slot1: Int

    init(shape: LayoutShape, span: TileSpan) {
        self.shape = shape
        self.lane0 = span.lane0
        self.lane1 = span.lane1
        self.slot0 = span.slot0
        self.slot1 = span.slot1
    }

    var span: TileSpan { TileSpan(lane0: lane0, lane1: lane1, slot0: slot0, slot1: slot1) }

    // Codable migration: legacy (v1) payloads encoded a single `lane`
    // field. Decode it as `lane0 == lane1`. New writes always use both.
    enum CodingKeys: String, CodingKey {
        case shape, lane, lane0, lane1, slot0, slot1
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shape, forKey: .shape)
        try c.encode(lane0, forKey: .lane0)
        try c.encode(lane1, forKey: .lane1)
        try c.encode(slot0, forKey: .slot0)
        try c.encode(slot1, forKey: .slot1)
    }
}

final class WindowMemory {
    private var entries: [LayoutShape: [WindowMemoryKey: TileSpan]] = [:]
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

    func recall(appId: String, title: String, shape: LayoutShape) -> TileSpan? {
        entries[shape]?[WindowMemoryKey(appId: appId, windowTitle: title)]
    }

    // MARK: mutation

    func remember(appId: String, title: String, shape: LayoutShape, span: TileSpan) {
        let key = WindowMemoryKey(appId: appId, windowTitle: title)
        var byShape = entries[shape] ?? [:]
        byShape[key] = span
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
        var rebuilt: [LayoutShape: [WindowMemoryKey: TileSpan]] = [:]
        for keyed in decoded.entries {
            var byShape = rebuilt[keyed.entry.shape] ?? [:]
            byShape[keyed.key] = keyed.entry.span
            rebuilt[keyed.entry.shape] = byShape
        }
        entries = rebuilt
    }

    func save() {
        var flat: [Keyed] = []
        for (shape, byKey) in entries {
            for (key, span) in byKey {
                flat.append(Keyed(key: key, entry: WindowMemoryEntry(shape: shape, span: span)))
            }
        }
        let payload = OnDisk(version: 2, entries: flat)
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
