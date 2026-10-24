import AppKit
import Common
import Foundation

/// `mur open-layout <name> [dir]` — rebuild a layout template on the next
/// free workspace, launching its apps in `dir`; see `LayoutLaunch`.
struct OpenLayoutCommand: Command {
    let args: OpenLayoutCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        guard config.experimentalStackingLayout else {
            io.err("open-layout requires `experimental-stacking-layout = true` in mur.toml")
            return .fail
        }
        let name = args.name.val
        let url = LayoutTemplateFiles.url(name, cwd: args.cwd)
        guard let toml = try? String(contentsOf: url, encoding: .utf8) else {
            let known = LayoutTemplateFiles.names
            io.err("no layout template at \(url.path)"
                + (known.isEmpty ? "" : "\nsaved templates: \(known.joined(separator: ", "))"))
            return .fail
        }
        let template: LayoutTemplate
        do {
            template = try LayoutTemplate.parse(toml)
        } catch {
            io.err("\(url.path): \(error)")
            return .fail
        }
        guard !template.cells.isEmpty else {
            io.err("\(url.path) has no windows")
            return .fail
        }

        let directory = resolvePath(args.dir ?? args.cwd ?? "~", cwd: args.cwd)
        guard (try? URL(filePath: directory).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            io.err("not a directory: \(directory)")
            return .fail
        }
        let workspace: Workspace = if let explicit = args.workspaceName?.raw {
            Workspace.get(byName: explicit)
        } else {
            nextFreeWorkspace()
        }
        _ = workspace.focusWorkspace()

        let launch = LayoutLaunch(template: template, workspace: workspace, directory: directory)
        activeLayoutLaunches.append(launch)
        launch.start()
        io.out("workspace \(workspace.name): launching \(template.cells.count) windows in \(directory)")
        return .succ
    }
}
