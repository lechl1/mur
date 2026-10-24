import AppKit
import Common
import Foundation

/// mur — `open-layout` at runtime: launch a template's apps and hand each
/// window that appears its cell (see `LayoutTemplate`).
///
/// A launched app's window is recognised by its BUNDLE ID when it registers
/// (`claimTemplateCell`, called from `tryRegisterInStackingLayout`) — there
/// is nothing else to know it by: no title yet, and `open` doesn't say
/// which window it made. So the windows of ONE app are launched one at a
/// time, each only after the previous one showed up (or was given up on);
/// two terminals running different commands would otherwise be
/// interchangeable. Different apps launch in parallel.
@MainActor
final class LayoutLaunch {
    let template: LayoutTemplate
    let workspace: Workspace
    let directory: String
    /// Cells still to launch, per app, in template order.
    private var queues: [String: [LayoutTemplate.Cell]] = [:]
    /// The cell whose window each app is launching right now, and when it was launched.
    private var waiting: [String: (cell: LayoutTemplate.Cell, generation: Int)] = [:]
    private var generation = 0
    private(set) var placed: [WindowId: LayoutTemplate.Cell] = [:]

    /// How long a launched window may take to appear (a cold IDE start is slow).
    static let windowTimeout: TimeInterval = 90

    init(template: LayoutTemplate, workspace: Workspace, directory: String) {
        self.template = template
        self.workspace = workspace
        self.directory = directory
        for (cell, item) in template.cells { queues[item.app, default: []].append(cell) }
    }

    var isDone: Bool { queues.values.allSatisfy(\.isEmpty) && waiting.isEmpty }

    func start() {
        for app in queues.keys.sorted() { launchNext(app) }
    }

    private func item(_ cell: LayoutTemplate.Cell) -> LayoutTemplate.Item {
        template.column[cell.column].window[cell.row]
    }

    private func launchNext(_ app: String) {
        guard var queue = queues[app], !queue.isEmpty else {
            waiting.removeValue(forKey: app)
            finishIfDone()
            return
        }
        let cell = queue.removeFirst()
        queues[app] = queue
        generation += 1
        let gen = generation
        waiting[app] = (cell, gen)
        runLaunchCommand(item(cell).launch, in: directory)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.windowTimeout * 1_000_000_000))
            guard let self, self.waiting[app]?.generation == gen else { return }
            fputs("mur open-layout: no \(app) window appeared for column \(cell.column + 1) row \(cell.row + 1); giving up on it\n", stderr)
            self.launchNext(app)
        }
    }

    /// Take `window` if this launch is waiting for a window of its app.
    func claim(_ window: Window) -> Bool {
        guard let app = window.app.rawAppBundleId, let (cell, _) = waiting[app] else { return false }
        if window.nodeWorkspace != workspace || window.isFloating {
            window.nodeWorkspace?.stackingLayout.remove(window.windowId)
            window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        let layout = workspace.stackingLayout
        layout.placeFromTemplate(window.windowId, at: cell, placed: placed)
        placed[window.windowId] = cell
        layout.applyTemplateSizes(template, placed: placed)
        templatePlacedIds.insert(window.windowId)
        launchNext(app)
        return true
    }

    private func finishIfDone() {
        guard isDone else { return }
        activeLayoutLaunches.removeAll { $0 === self }
        persistWindowStateAfterOpen()
    }
}

/// Launches still waiting for windows, oldest first.
@MainActor var activeLayoutLaunches: [LayoutLaunch] = []
/// Windows a launch has placed: the restore that runs after every
/// registration must leave them in their cell.
@MainActor var templatePlacedIds: Set<WindowId> = []

/// Called as a window registers: put it in a pending template cell.
@MainActor
func claimTemplateCell(_ window: Window) -> Bool {
    // A copy: a claim that finishes its launch removes it from the list.
    let launches = activeLayoutLaunches
    return launches.contains { $0.claim(window) }
}

/// Run `command` through the user's login shell in `directory`, with
/// `$MUR_DIR` set to it. Not waited for: `open` returns at once, and a
/// command that doesn't must not hold mur up.
@MainActor
private func runLaunchCommand(_ command: String, in directory: String) {
    let process = Process()
    let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    process.executableURL = URL(filePath: shell)
    process.arguments = ["-lc", command]
    process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
    var env = ProcessInfo.processInfo.environment
    env["MUR_DIR"] = directory
    process.environment = env
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        fputs("mur open-layout: can't run \(command): \(error)\n", stderr)
    }
}

// MARK: Files

enum LayoutTemplateFiles {
    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mur/layouts", isDirectory: true)

    /// A bare name is a file in `directory`; anything with a slash or a
    /// `.toml` suffix is a path, relative to `cwd`.
    static func url(_ name: String, cwd: String?) -> URL {
        if name.contains("/") || name.hasSuffix(".toml") {
            return URL(filePath: resolvePath(name, cwd: cwd))
        }
        return directory.appendingPathComponent("\(name).toml")
    }

    static var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".toml") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }
}

func resolvePath(_ path: String, cwd: String?) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
    let base = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
    return ((base as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
}

/// The first empty workspace, in the order the user listed their
/// workspaces; one another launch is still filling doesn't count.
@MainActor
func nextFreeWorkspace() -> Workspace {
    let taken = Set(activeLayoutLaunches.map(\.workspace.name))
    let free: (Workspace) -> Bool = {
        $0.isEffectivelyEmpty && !taken.contains($0.name) && (!$0.isVisible || $0 == focus.workspace)
    }
    let names = config.persistentWorkspaces.isEmpty ? Workspace.all.map(\.name) : Array(config.persistentWorkspaces)
    if let ws = names.lazy.map({ Workspace.get(byName: $0) }).first(where: free) { return ws }
    return (1 ... Int.max).lazy.map { Workspace.get(byName: String($0)) }.first(where: free).orDie("no free workspace")
}

// MARK: Capture

/// The template for `workspace` as it is on screen now.
@MainActor
func captureLayoutTemplate(_ workspace: Workspace, base explicitBase: String?) async -> LayoutTemplate {
    let layout = workspace.stackingLayout
    var captured: [[(window: CapturedWindow, height: Double)]] = []
    var widths: [Double] = []
    var tabs: [String: [(title: String, url: String)]] = [:]
    for lane in layout.usedLanes {
        let ids = layout.windows(in: lane).filter { layout.placements[$0]?.lane0 == lane }
        let total = ids.reduce(0.0) { $0 + Double(layout.slotWeight(lane: lane, slot: layout.placements[$1]?.slot0 ?? 0)) }
        var column: [(window: CapturedWindow, height: Double)] = []
        for id in ids {
            guard let window = Window.get(byId: id), let appId = window.app.rawAppBundleId else { continue }
            var w = CapturedWindow(appId: appId, title: (try? await window.title) ?? "")
            if appId == LaunchGuess.ghostty { w.cwd = await resolveTerminalCwd(window) }
            if LaunchGuess.chromiumBrowsers.contains(appId) {
                if tabs[appId] == nil { tabs[appId] = await browserWindowUrls(appId) }
                // AX titles carry the app's name (" - Helium"); AppleScript's don't.
                w.url = tabs[appId]?.first { w.title == $0.title || w.title.hasPrefix($0.title + " - ") }?.url
            }
            let weight = Double(layout.slotWeight(lane: lane, slot: layout.placements[id]?.slot0 ?? 0))
            column.append((w, total > 0 ? weight / total : 1))
        }
        guard !column.isEmpty else { continue }
        captured.append(column)
        widths.append(Double(layout.laneWeight(lane: lane)))
    }
    let base = explicitBase ?? LaunchGuess.baseDirectory(captured.flatMap { $0.compactMap(\.window.cwd) })
    return LayoutTemplate(column: zip(widths, captured).map { width, column in
        LayoutTemplate.Column(width: width, window: column.map { w, height in
            LayoutTemplate.Item(app: w.appId, height: height, launch: LaunchGuess.launch(for: w, base: base), note: w.title)
        })
    })
}

/// Title and active-tab URL of every window of a Chromium browser, over
/// AppleScript. Bounded: the first ask raises an Automation prompt, and an
/// unanswered prompt must not stall `save-layout`.
private func browserWindowUrls(_ appId: String) async -> [(title: String, url: String)] {
    await Task.detached { () -> [(title: String, url: String)] in
        // `character id 9`, not `tab`: inside the tell block `tab` is the browser's tab class.
        let script = """
            set sep to character id 9
            set nl to character id 10
            tell application id "\(appId)"
                set out to ""
                repeat with w in windows
                    set out to out & (title of w) & sep & (URL of active tab of w) & nl
                end repeat
                return out
            end tell
            """
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        guard (try? process.run()) != nil else { return [] }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errors = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        if process.terminationStatus != 0 {
            // Most likely Automation access (System Settings → Privacy & Security → Automation).
            fputs("mur save-layout: can't read \(appId)'s URLs: \(String(decoding: errors, as: UTF8.self))\n", stderr)
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }.value
}
