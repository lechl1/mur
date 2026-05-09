// mur — phase 2 CLI command. Read-only inspection of the grid layout
// state for a workspace. Output is plain text intended for humans;
// stable enough to grep but not promised as machine-parseable.
public struct StackingInfoCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .stackingInfo,
        allowInConfig: false,
        help: stacking_info_help_generated,
        flags: [
            "--workspace": workspaceSubArgParser(),
        ],
        posArgs: [],
    )
}
