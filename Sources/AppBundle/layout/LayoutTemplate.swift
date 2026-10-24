import AppKit
import Common
import Foundation
import TOMLDecoder

/// mur — a workspace's layout saved as a TEMPLATE: its columns, their rows,
/// and for every cell a shell command that opens one new window of its app.
/// `save-layout` writes one from a live workspace, `open-layout` rebuilds it
/// on the next free workspace in any directory (`$MUR_DIR`).
///
/// Unlike `Arrangement` (which remembers *these* windows so they come back
/// after a restart), a template names no window: it says what to launch and
/// where to put what appears. Stored as TOML so it can be edited by hand.
struct LayoutTemplate: Codable, Equatable {
    /// Columns in lane order (left → right; top → bottom on a portrait monitor).
    var column: [Column]

    struct Column: Codable, Equatable {
        /// Absolute width as a fraction of the lane axis — a lane weight.
        var width: Double
        /// Rows, top → bottom.
        var window: [Item]
    }

    struct Item: Codable, Equatable {
        /// Bundle id of the app whose next new window takes this cell.
        var app: String
        /// The row's share of its column (slot weight). Default 1.
        var height: Double?
        /// Shell command that opens ONE new window of `app`; runs in the
        /// target directory, which is also `$MUR_DIR`.
        var launch: String
        /// The title the window had when saved — written as a comment only.
        var note: String? = nil

        enum CodingKeys: String, CodingKey { case app, height, launch }
    }

    /// A template cell: column index and row index within it.
    struct Cell: Hashable { let column: Int; let row: Int }

    var cells: [(cell: Cell, item: Item)] {
        column.enumerated().flatMap { c, col in
            col.window.enumerated().map { r, item in (Cell(column: c, row: r), item) }
        }
    }

    static func parse(_ toml: String) throws -> LayoutTemplate {
        try TOMLDecoder().decode(LayoutTemplate.self, from: toml)
    }

    func toToml(header: [String]) -> String {
        var out = header.map { "# \($0)" }
        out.append(contentsOf: [
            "#",
            "# Each [[column]] is one column (a row on a portrait monitor), left to",
            "# right; its [[column.window]] entries are its rows, top to bottom.",
            "#   width  - the column's width as a fraction of the screen",
            "#   height - the row's share of its column",
            "#   launch - a shell command that opens ONE new window of `app`. It runs",
            "#            in the directory open-layout was given, also in $MUR_DIR.",
        ])
        for col in column {
            out.append("")
            out.append("[[column]]")
            out.append("width = \(Self.number(col.width))")
            for item in col.window {
                out.append("")
                out.append("  [[column.window]]")
                if let note = item.note, !note.isEmpty {
                    out.append("  # was: \(note.replacingOccurrences(of: "\n", with: " "))")
                }
                out.append("  app = \(Self.tomlString(item.app))")
                if let h = item.height { out.append("  height = \(Self.number(h))") }
                out.append("  launch = \(Self.tomlString(item.launch))")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func number(_ x: Double) -> String { String(format: "%.3f", x) }

    /// A TOML string that reads like the shell command it holds: a literal
    /// '…' string, or '''…''' when the command has single quotes itself
    /// (launch commands are full of both kinds), else an escaped basic one.
    static func tomlString(_ s: String) -> String {
        let plain = !s.contains(where: { $0.isNewline || ($0.asciiValue.map { $0 < 0x20 } ?? false) })
        if plain, !s.contains("'") { return "'\(s)'" }
        // A quote touching the delimiter would merge with it; a space keeps
        // them apart, and is nothing to a shell command.
        if plain, !s.contains("'''") {
            return "'''" + (s.hasPrefix("'") ? " " : "") + s + (s.hasSuffix("'") ? " " : "") + "'''"
        }
        var escaped = ""
        for ch in s.unicodeScalars {
            switch ch {
                case "\\": escaped += "\\\\"
                case "\"": escaped += "\\\""
                case "\n": escaped += "\\n"
                case "\t": escaped += "\\t"
                case "\r": escaped += "\\r"
                default:
                    if ch.value < 0x20 || ch.value == 0x7F {
                        escaped += String(format: "\\u%04X", ch.value)
                    } else {
                        escaped.unicodeScalars.append(ch)
                    }
            }
        }
        return "\"\(escaped)\""
    }
}

// MARK: Guessing how to reopen a window

/// What `save-layout` knows about one window when it writes its `launch`.
struct CapturedWindow {
    let appId: String
    let title: String
    /// Terminal working directory, if one could be read.
    var cwd: String? = nil
    /// The URL a browser window shows, if one could be read.
    var url: String? = nil
}

enum LaunchGuess {
    static let ghostty = "com.mitchellh.ghostty"
    /// Browsers that take `--new-window <url>` on the command line and hand
    /// it to the running instance, and answer `URL of active tab` in
    /// AppleScript.
    static let chromiumBrowsers: Set<String> = [
        "net.imput.helium", "com.google.Chrome", "com.brave.Browser", "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
    ]
    /// Editors that open a directory passed as a document in a new window.
    static let directoryEditors: Set<String> = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4",
    ]

    static func isJetBrains(_ appId: String) -> Bool {
        appId.hasPrefix("com.jetbrains.") || appId == "com.google.android.studio"
    }

    /// The directory most of these terminals are in — what a template's
    /// paths are made relative to when `save-layout` isn't told.
    static func baseDirectory(_ cwds: [String]) -> String? {
        let counts = Dictionary(grouping: cwds, by: { $0 }).mapValues(\.count)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// `path` as a shell word, relative to `$MUR_DIR` when it is under `base`.
    static func directoryWord(_ path: String, base: String?) -> String {
        if let base {
            if path == base { return "\"$MUR_DIR\"" }
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) {
                return "\"$MUR_DIR\"/" + shellQuote(String(path.dropFirst(prefix.count)))
            }
        }
        return shellQuote(path)
    }

    /// What a terminal was running, read off its title. Ghostty's shell
    /// integration titles a window with the command in the foreground, and
    /// with the directory at a prompt; Claude Code prefixes its title with a
    /// status glyph (✳ ◐ ⠂ …).
    static func terminalCommand(title: String) -> String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard let first = t.first else { return nil }
        if first == "~" || first == "/" { return nil }
        if !(first.isLetter || first.isNumber) { return "claude" }
        return t
    }

    static func launch(for w: CapturedWindow, base: String?) -> String {
        let app = shellQuote(w.appId)
        if w.appId == ghostty {
            var cmd = "open -n -b \(app) --args --working-directory=\(directoryWord(w.cwd ?? base ?? "~", base: base))"
            // Typed into the user's own shell (`input`), not run with `-e`:
            // `-e` opens a second tab beside the command's, and a command run
            // in place of the shell has no shell integration (no cwd for mur
            // to read) and takes the window with it when it exits.
            if let run = terminalCommand(title: w.title) {
                cmd += " --input=" + shellQuote(run) + "$'\\n'"
            }
            return cmd
        }
        if chromiumBrowsers.contains(w.appId) {
            return "open -n -b \(app) --args --new-window" + (w.url.map { " " + shellQuote($0) } ?? "")
        }
        // A directory handed to the running IDE / editor opens a new project
        // window. (`open -n … --args <dir>` makes JetBrains IDEs do nothing.)
        if isJetBrains(w.appId) || directoryEditors.contains(w.appId) {
            return "open -b \(app) \"$MUR_DIR\""
        }
        return "open -b \(app)"
    }
}

func shellQuote(_ s: String) -> String {
    if !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0)) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: Rebuilding a template in the grid

extension StackingLayout {
    /// Put `windowId` in template cell `cell`, given the cells of the windows
    /// from the same template that are already placed (`placed`). Windows
    /// arrive in any order, and lanes and slots are compacted after every
    /// placement, so the target is computed from RANKS: the window goes in
    /// the lane that already holds its column, below the rows above it —
    /// or in a new lane right after the columns to its left.
    func placeFromTemplate(_ windowId: WindowId, at cell: LayoutTemplate.Cell, placed: [WindowId: LayoutTemplate.Cell]) {
        let live = placed.filter { $0.key != windowId && placements[$0.key] != nil }
        if let lane = live.first(where: { $0.value.column == cell.column }).flatMap({ placements[$0.key]?.lane0 }) {
            let slot = live.count(where: { $0.value.column == cell.column && $0.value.row < cell.row })
            place(windowId, at: .single(lane: lane, slot: slot))
            return
        }
        let left = live.filter { $0.value.column < cell.column }.compactMap { placements[$0.key]?.lane1 }
        let lane = (left.max() ?? -1) + 1
        if usedLanes.contains(lane) {
            insertLane(at: lane)
        } else if lane >= shape.lanes {
            _ = appendLane()
        }
        place(windowId, at: .single(lane: lane, slot: 0))
    }

    /// Give every lane and slot holding a template window its saved size.
    func applyTemplateSizes(_ template: LayoutTemplate, placed: [WindowId: LayoutTemplate.Cell]) {
        var widths: [CGFloat] = (0 ..< shape.lanes).map { laneWeight(lane: $0) }
        for lane in usedLanes {
            let ids = windows(in: lane)
            guard let column = ids.lazy.compactMap({ placed[$0]?.column }).first,
                  column < template.column.count else { continue }
            widths[lane] = max(0.01, template.column[column].width)
            var heights: [CGFloat] = (0 ..< slotCount(in: lane)).map { slotWeight(lane: lane, slot: $0) }
            for id in ids {
                guard let cell = placed[id], let span = placements[id], span.slot0 == span.slot1,
                      span.slot0 < heights.count, cell.column == column,
                      cell.row < template.column[column].window.count else { continue }
                heights[span.slot0] = max(0.01, template.column[column].window[cell.row].height ?? 1)
            }
            setSlotWeights(lane: lane, weights: heights)
        }
        setLaneWeights(widths)
    }
}
