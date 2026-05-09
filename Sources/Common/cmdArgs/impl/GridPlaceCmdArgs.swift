// mur — phase 2 CLI command. Manually place the focused (or
// --window-id) window at an explicit (lane, slot0..slot1) span.
// Useful for scripting and as a key binding ("send this window to the
// right lane bottom slot").
public struct GridPlaceCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .gridPlace,
        allowInConfig: true,
        help: grid_place_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
            "--workspace": workspaceSubArgParser(),
        ],
        posArgs: [
            newMandatoryPosArgParser(\.lane,  parseGridIndex, placeholder: "<lane>"),
            newMandatoryPosArgParser(\.slot0, parseGridIndex, placeholder: "<slot0>"),
            newMandatoryPosArgParser(\.slot1, parseGridIndex, placeholder: "<slot1>"),
        ],
    )

    public var lane:  Lateinit<Int> = .uninitialized
    public var slot0: Lateinit<Int> = .uninitialized
    public var slot1: Lateinit<Int> = .uninitialized

    public init(rawArgs: [String], lane: Int, slot0: Int, slot1: Int) {
        self.commonState = .init(rawArgs.slice)
        self.lane = .initialized(lane)
        self.slot0 = .initialized(slot0)
        self.slot1 = .initialized(slot1)
    }
}

public func parseGridPlaceCmdArgs(_ args: StrArrSlice) -> ParsedCmd<GridPlaceCmdArgs> {
    parseSpecificCmdArgs(GridPlaceCmdArgs(rawArgs: args), args)
}

private func parseGridIndex(i: PosArgParserInput) -> ParsedCliArgs<Int> {
    if let n = Int(i.arg), n >= 0 {
        return .succ(n, advanceBy: 1)
    }
    return .fail("Expected a non-negative integer, got '\(i.arg)'", advanceBy: 1)
}
