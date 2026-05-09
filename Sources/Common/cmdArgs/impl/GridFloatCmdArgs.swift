// mur — phase 2 CLI command. Take the focused (or --window-id) window
// out of the grid and float it. Forgets the WindowMemory entry so a
// subsequent reopen doesn't auto-restore back into the grid.
public struct GridFloatCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .gridFloat,
        allowInConfig: true,
        help: grid_float_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
            "--workspace": workspaceSubArgParser(),
        ],
        posArgs: [],
    )
}
