// mur — capture a workspace's columns, rows and apps as a layout template
// that `open-layout` rebuilds on a free workspace, in any directory.
public struct SaveLayoutCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .saveLayout,
        allowInConfig: true,
        help: save_layout_help_generated,
        flags: [
            "--workspace": workspaceSubArgParser(),
            "--dir": singleValueSubArgParser(\.dir, "<dir>", Result.success),
            "--cwd": singleValueSubArgParser(\.cwd, "<cwd>", Result.success),
        ],
        posArgs: [newMandatoryPosArgParser(\.name, consumeStrCliArg, placeholder: "<name>")],
    )

    public var name: Lateinit<String> = .uninitialized
    /// The directory the captured terminals and editors are relative to.
    public var dir: String? = nil
    /// The CLI's working directory, which relative paths resolve against.
    /// The CLI appends it; the server has a cwd of its own.
    public var cwd: String? = nil
}
