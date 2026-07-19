import AppKit
import Common
import Foundation

/// mur — terminal session restore (inspired by naru's Konsole restore).
///
/// A terminal window's **working directory** is read from its AX
/// represented-document URL (`Ax.documentAttr` → `file://…`); terminals with
/// shell integration (Ghostty, Terminal.app, iTerm2, …) set it. That cwd is
/// the stable session identity — window ids and titles change, the cwd does
/// not — so mur keys sessions by cwd, exactly like naru matches restored
/// terminals by cwd.
///
/// Two things are persisted per terminal window: its cwd + grid position
/// (so a reopened window restores to the same cell by cwd, more reliably
/// than by title), and whether `claude` was running in it (so a relaunch can
/// resume it). On startup, if `experimental-session-restore` is on, a saved
/// session whose window is no longer open is relaunched in its cwd.

/// A persisted terminal session, keyed by working directory.
struct TerminalSession: Codable, Equatable {
    enum Kind: String, Codable { case shell, claude }
    let cwd: String
    let kind: Kind
    let workspace: String
    let lane0: Int
    let lane1: Int
    let slot0: Int
    let slot1: Int

    init(cwd: String, kind: Kind, workspace: String, span: TileSpan) {
        self.cwd = cwd
        self.kind = kind
        self.workspace = workspace
        self.lane0 = span.lane0
        self.lane1 = span.lane1
        self.slot0 = span.slot0
        self.slot1 = span.slot1
    }

    var span: TileSpan { TileSpan(lane0: lane0, lane1: lane1, slot0: slot0, slot1: slot1) }
}

@MainActor let terminalSessionStore = TerminalSessionStore()

final class TerminalSessionStore {
    private(set) var byCwd: [String: TerminalSession] = [:]
    private let url: URL

    init(url: URL = TerminalSessionStore.defaultURL()) {
        self.url = url
        load()
    }

    static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("mur", isDirectory: true)
            .appendingPathComponent("terminal-sessions.json")
    }

    func recall(cwd: String) -> TerminalSession? { byCwd[cwd] }
    func remember(_ session: TerminalSession) { byCwd[session.cwd] = session }
    func forget(cwd: String) { byCwd.removeValue(forKey: cwd) }
    var all: [TerminalSession] { Array(byCwd.values) }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([TerminalSession].self, from: data) else { return }
        byCwd = Dictionary(arr.map { ($0.cwd, $0) }, uniquingKeysWith: { _, b in b })
    }

    func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Bundle ids treated as terminals for session restore. Ghostty is the
/// verified target (its window exposes cwd via AXDocument); extend as other
/// terminals are confirmed to do the same.
@MainActor let sessionRestoreTerminalBundleIds: Set<String> = [
    "com.mitchellh.ghostty",
]

// Editable launch recipe. `%CWD%` is replaced with the session's cwd.
// The window is spawned via `open -na <app> --args <argv>`. The claude
// argv is where you enable remote control — append the flag your Claude
// Code build uses (mur can't verify it, so it's left to you here).
@MainActor let sessionRestoreGhosttyAppPath = "/Applications/Ghostty.app"
@MainActor let sessionRestoreShellArgv: [String] = ["--working-directory=%CWD%"]
@MainActor let sessionRestoreClaudeArgv: [String] = ["--working-directory=%CWD%", "-e", "claude", "--resume"]

/// Record/refresh the terminal session for `window` (cwd + whether claude is
/// running in it + current grid span). No-op for non-terminals. Async: reads
/// the cwd via AX and scans processes off the main thread.
@MainActor
func captureTerminalSession(_ window: Window, in workspace: Workspace) {
    let appId = window.app.rawAppBundleId ?? ""
    guard sessionRestoreTerminalBundleIds.contains(appId) else { return }
    let windowId = window.windowId
    Task { @MainActor in
        guard let cwd = try? await window.cwd, !cwd.isEmpty,
              let span = workspace.stackingLayout.placements[windowId] else { return }
        let kind: TerminalSession.Kind = await claudeCwds().contains(cwd) ? .claude : .shell
        terminalSessionStore.remember(TerminalSession(cwd: cwd, kind: kind, workspace: workspace.name, span: span))
        terminalSessionStore.save()
    }
}

/// On startup, relaunch each saved terminal session whose window is no
/// longer open, in its cwd (resuming claude if it was a claude session).
/// Gated by `experimental-session-restore`.
@MainActor
func relaunchMissingTerminalSessions() {
    guard config.experimentalSessionRestore else { return }
    Task { @MainActor in
        var openCwds = Set<String>()
        for window in MacWindow.allWindows {
            let appId = window.app.rawAppBundleId ?? ""
            guard sessionRestoreTerminalBundleIds.contains(appId) else { continue }
            if let cwd = try? await window.cwd, !cwd.isEmpty { openCwds.insert(cwd) }
        }
        for session in terminalSessionStore.all
            where !openCwds.contains(session.cwd) && FileManager.default.fileExists(atPath: session.cwd)
        {
            spawnTerminalSession(session)
        }
    }
}

@MainActor
private func spawnTerminalSession(_ session: TerminalSession) {
    let argv = (session.kind == .claude ? sessionRestoreClaudeArgv : sessionRestoreShellArgv)
        .map { $0.replacingOccurrences(of: "%CWD%", with: session.cwd) }
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/open")
    process.arguments = ["-na", sessionRestoreGhosttyAppPath, "--args"] + argv
    _ = try? process.run()
}

/// Set of working directories that currently have a `claude` process, read
/// off the main thread. Used to tag a captured session as `.claude`.
private func claudeCwds() async -> Set<String> {
    await Task.detached { () -> Set<String> in
        let script = "for p in $(/usr/bin/pgrep -f '[c]laude' 2>/dev/null); do "
            + "/usr/sbin/lsof -a -p \"$p\" -d cwd -Fn 2>/dev/null | /usr/bin/sed -n 's/^n//p'; done | /usr/bin/sort -u"
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Set(String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }.value
}
