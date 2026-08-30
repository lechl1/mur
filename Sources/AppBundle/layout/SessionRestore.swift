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
        lastKnownTerminalCwd[windowId] = cwd
        terminalSessionStore.remember(TerminalSession(cwd: cwd, kind: kind, workspace: workspace.name, span: span))
        terminalSessionStore.save()
    }
}

/// mur — record every open terminal's session in one pass: one process scan
/// for the whole sweep instead of one per window. Called from
/// `persistWindowStateNow` after windows open and after moves, so a session
/// whose cwd wasn't published yet at open time still lands on disk.
@MainActor
func captureAllTerminalSessions() async {
    let claude = await claudeCwds()
    for workspace in Workspace.all {
        for (windowId, span) in workspace.stackingLayout.placements {
            guard let window = Window.get(byId: windowId) else { continue }
            guard sessionRestoreTerminalBundleIds.contains(window.app.rawAppBundleId ?? "") else { continue }
            guard let cwd = await resolveTerminalCwd(window) else { continue }
            lastKnownTerminalCwd[windowId] = cwd
            terminalSessionStore.remember(TerminalSession(
                cwd: cwd,
                kind: claude.contains(cwd) ? .claude : .shell,
                workspace: workspace.name,
                span: span,
            ))
        }
    }
    terminalSessionStore.save()
}

/// mur — the last cwd mur saw for each terminal window. A closed window's
/// `AXDocument` can't be read any more, so the mapping has to be kept while
/// the window is alive to know which session just went away.
@MainActor private var lastKnownTerminalCwd: [UInt32: String] = [:]

/// mur — a terminal window closed: stop restoring its session. Without this
/// the store only ever grows, and a terminal the user deliberately closed
/// gets resurrected — with `claude --resume` — on every single restart.
///
/// Deliberately DELAYED. At logout / shutdown every window closes at once
/// while mur is still up; pruning immediately would wipe the very snapshot
/// the next boot is supposed to restore from. mur is normally gone long
/// before the delay elapses, so the file keeps its pre-shutdown state.
@MainActor
func forgetTerminalSessionOnWindowClose(_ windowId: UInt32) {
    guard let cwd = lastKnownTerminalCwd.removeValue(forKey: windowId) else { return }
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        // Another terminal may still be sitting in that directory (several
        // claude sessions in one repo is normal) — then the session lives on.
        if await openTerminalCwds().contains(cwd) { return }
        terminalSessionStore.forget(cwd: cwd)
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
        // mur — WAIT FOR THE WINDOW SET TO SETTLE FIRST. This runs off the
        // first coordinated restore, ~90ms after the first window registers,
        // when most terminals aren't in `MacWindow.allWindows` yet and the
        // ones that are haven't published `AXDocument` (the cwd) either. Ask
        // right then and every saved session looks "missing", so mur
        // relaunches sessions whose windows are open and running — the
        // "session restore triggers on every restart" symptom. Poll until
        // the observed cwd set stops growing, then decide.
        var openCwds = await openTerminalCwds()
        for _ in 0 ..< 12 { // ≤ 6s
            try? await Task.sleep(nanoseconds: 500_000_000)
            let again = await openTerminalCwds()
            let settled = again == openCwds && !again.isEmpty
            openCwds.formUnion(again)
            if settled { break }
        }
        // Fail safe: terminals ARE open but not one of them reported a cwd
        // (no shell integration, or AXDocument still empty). Relaunching
        // from here would duplicate every session — and a `claude` session
        // is expensive to duplicate — so skip this round entirely.
        let terminalsOpen = MacWindow.allWindows.contains {
            sessionRestoreTerminalBundleIds.contains($0.app.rawAppBundleId ?? "")
        }
        if openCwds.isEmpty && terminalsOpen { return }
        for session in terminalSessionStore.all
            where !openCwds.contains(session.cwd) && FileManager.default.fileExists(atPath: session.cwd)
        {
            spawnTerminalSession(session)
        }
    }
}

/// Working directories of the terminal windows mur currently knows about.
@MainActor
private func openTerminalCwds() async -> Set<String> {
    var cwds = Set<String>()
    for window in MacWindow.allWindows {
        let appId = window.app.rawAppBundleId ?? ""
        guard sessionRestoreTerminalBundleIds.contains(appId) else { continue }
        if let cwd = await resolveTerminalCwd(window) { cwds.insert(cwd) }
    }
    return cwds
}

/// mur — cwd of a terminal mur has just relaunched, and when. A session
/// mur spawns runs `claude` DIRECTLY (no shell), so no shell integration
/// runs and Ghostty never publishes `AXDocument` — mur can't read that
/// window's cwd, ever. Left at that, the session is never re-recorded, its
/// window never matches on the next start, and mur relaunches a duplicate
/// at every restart. Adopting the spawn's cwd for the window that shows up
/// right after closes the loop.
@MainActor private var pendingSpawnedCwds: [(cwd: String, at: Date)] = []

/// This window's cwd: what it reports, else what mur last saw, else the
/// session mur just spawned (see `pendingSpawnedCwds`).
@MainActor
private func resolveTerminalCwd(_ window: Window) async -> String? {
    if let cwd = try? await window.cwd, !cwd.isEmpty { return cwd }
    if let known = lastKnownTerminalCwd[window.windowId] { return known }
    let cutoff = Date.now.addingTimeInterval(-120)
    pendingSpawnedCwds.removeAll { $0.at < cutoff }
    guard !pendingSpawnedCwds.isEmpty else { return nil }
    return pendingSpawnedCwds.removeFirst().cwd
}

@MainActor
private func spawnTerminalSession(_ session: TerminalSession) {
    pendingSpawnedCwds.append((cwd: session.cwd, at: .now))
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
