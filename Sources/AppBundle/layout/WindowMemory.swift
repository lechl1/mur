import AppKit
import Common
import Foundation

/// Per (app bundle id, window title) memory of the last `TileSpan` the user
/// placed a window in. When a matching window opens later, mur restores the
/// span instead of running the placement heuristic.
///
/// Persisted to `~/.config/mur/window-memory.json` so memory survives
/// restarts. Save is debounced by the caller; this type is sync.
struct WindowMemoryKey: Hashable, Codable {
    let appId: String
    let windowTitle: String
}

/// On-disk record. The `shape` field lets future grid shapes have
/// independent memory ("3×3 layout remembers Slack at col=0, but the 4×3
/// layout remembers Slack at col=1").
struct WindowMemoryEntry: Codable, Equatable {
    let cols: Int
    let rows: Int
    let col0: Int
    let row0: Int
    let col1: Int
    let row1: Int

    init(shape: GridShape, span: TileSpan) {
        self.cols = shape.cols
        self.rows = shape.rows
        self.col0 = span.col0
        self.row0 = span.row0
        self.col1 = span.col1
        self.row1 = span.row1
    }

    var shape: GridShape { GridShape(cols: cols, rows: rows) }
    var span: TileSpan { TileSpan(col0: col0, row0: row0, col1: col1, row1: row1) }
}

final class WindowMemory {
    /// Keyed by shape first so a layout switch (3×3 → 2×2) doesn't make
    /// memory entries for the previous shape pollute the new one.
    private var entries: [GridShape: [WindowMemoryKey: TileSpan]] = [:]
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

    func recall(appId: String, title: String, shape: GridShape) -> TileSpan? {
        entries[shape]?[WindowMemoryKey(appId: appId, windowTitle: title)]
    }

    // MARK: mutation

    func remember(appId: String, title: String, shape: GridShape, span: TileSpan) {
        let key = WindowMemoryKey(appId: appId, windowTitle: title)
        var byShape = entries[shape] ?? [:]
        byShape[key] = span
        entries[shape] = byShape
    }

    func forget(appId: String, title: String, shape: GridShape) {
        let key = WindowMemoryKey(appId: appId, windowTitle: title)
        entries[shape]?.removeValue(forKey: key)
        if entries[shape]?.isEmpty == true { entries.removeValue(forKey: shape) }
    }

    // MARK: persistence

    private struct OnDisk: Codable {
        let version: Int
        let entries: [WindowMemoryEntry_Keyed]
    }
    private struct WindowMemoryEntry_Keyed: Codable {
        let key: WindowMemoryKey
        let entry: WindowMemoryEntry
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard let decoded = try? JSONDecoder().decode(OnDisk.self, from: data) else { return }
        var rebuilt: [GridShape: [WindowMemoryKey: TileSpan]] = [:]
        for keyed in decoded.entries {
            var byShape = rebuilt[keyed.entry.shape] ?? [:]
            byShape[keyed.key] = keyed.entry.span
            rebuilt[keyed.entry.shape] = byShape
        }
        entries = rebuilt
    }

    func save() {
        var flat: [WindowMemoryEntry_Keyed] = []
        for (shape, byKey) in entries {
            for (key, span) in byKey {
                flat.append(WindowMemoryEntry_Keyed(
                    key: key,
                    entry: WindowMemoryEntry(shape: shape, span: span)
                ))
            }
        }
        let payload = OnDisk(version: 1, entries: flat)
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
