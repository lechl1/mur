import AppKit
import Common
import Foundation

/// `mur save-layout <name>` — write the focused (or `--workspace`)
/// workspace as a layout template; see `LayoutTemplate`.
struct SaveLayoutCommand: Command {
    let args: SaveLayoutCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        guard config.experimentalStackingLayout else {
            io.err("save-layout requires `experimental-stacking-layout = true` in mur.toml")
            return .fail
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        let base = args.dir.map { resolvePath($0, cwd: args.cwd) }
        let template = await captureLayoutTemplate(workspace, base: base)
        guard !template.column.isEmpty else {
            io.err("workspace \(workspace.name) has no tiled windows to save")
            return .fail
        }
        let name = args.name.val
        let url = LayoutTemplateFiles.url(name, cwd: args.cwd)
        let toml = template.toToml(header: [
            "mur layout template, saved from workspace \(workspace.name).",
            "Open it with:  mur open-layout \(name) [dir]",
        ])
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try toml.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            io.err("can't write \(url.path): \(error.localizedDescription)")
            return .fail
        }
        let count = template.column.reduce(0) { $0 + $1.window.count }
        io.out("saved \(template.column.count) columns, \(count) windows to \(url.path)")
        return .succ
    }
}
