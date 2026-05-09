// mur — phase 2 CLI command. Focus the topmost window at a given grid
// coordinate. If multiple windows overlap that cell, the one highest
// in zOrder wins.
public struct StackingFocusCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .stackingFocus,
        allowInConfig: true,
        help: stacking_focus_help_generated,
        flags: [
            "--workspace": workspaceSubArgParser(),
        ],
        posArgs: [
            newMandatoryPosArgParser(\.lane, parseStackingFocusIndex, placeholder: "<lane>"),
            newMandatoryPosArgParser(\.slot, parseStackingFocusIndex, placeholder: "<slot>"),
        ],
    )

    public var lane: Lateinit<Int> = .uninitialized
    public var slot: Lateinit<Int> = .uninitialized

    public init(rawArgs: [String], lane: Int, slot: Int) {
        self.commonState = .init(rawArgs.slice)
        self.lane = .initialized(lane)
        self.slot = .initialized(slot)
    }
}

public func parseStackingFocusCmdArgs(_ args: StrArrSlice) -> ParsedCmd<StackingFocusCmdArgs> {
    parseSpecificCmdArgs(StackingFocusCmdArgs(rawArgs: args), args)
}

private func parseStackingFocusIndex(i: PosArgParserInput) -> ParsedCliArgs<Int> {
    if let n = Int(i.arg), n >= 0 {
        return .succ(n, advanceBy: 1)
    }
    return .fail("Expected a non-negative integer, got '\(i.arg)'", advanceBy: 1)
}
