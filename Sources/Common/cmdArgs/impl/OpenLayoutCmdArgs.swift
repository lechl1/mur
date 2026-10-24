// mur — rebuild a saved layout template on the next free workspace:
// launch every app of it in a directory and put each new window in its cell.
public struct OpenLayoutCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .openLayout,
        allowInConfig: true,
        help: open_layout_help_generated,
        flags: [
            "--workspace": workspaceSubArgParser(),
            "--cwd": singleValueSubArgParser(\.cwd, "<cwd>", Result.success),
        ],
        posArgs: [
            newMandatoryPosArgParser(\.name, consumeStrCliArg, placeholder: "<name>"),
            ArgParser(\.dir, upcastArgParserFun(consumeStrCliArg)),
        ],
    )

    public var name: Lateinit<String> = .uninitialized
    /// Where the apps start. Defaults to `cwd`.
    public var dir: String? = nil
    /// The CLI's working directory (appended by the CLI, see `SaveLayoutCmdArgs.cwd`).
    public var cwd: String? = nil
}
