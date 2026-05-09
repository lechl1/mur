// mur — phase 2 CLI command. Manually place the focused (or
// --window-id) window at an explicit (lane, slot0..slot1) span.
// Useful for scripting and as a key binding ("send this window to the
// right lane bottom slot").
public struct StackingPlaceCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .stackingPlace,
        allowInConfig: true,
        help: stacking_place_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
            "--workspace": workspaceSubArgParser(),
        ],
        posArgs: [
            newMandatoryPosArgParser(\.lane,  parseStackingIndex, placeholder: "<lane>"),
            newMandatoryPosArgParser(\.slot0, parseStackingIndex, placeholder: "<slot0>"),
            newMandatoryPosArgParser(\.slot1, parseStackingIndex, placeholder: "<slot1>"),
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

public func parseStackingPlaceCmdArgs(_ args: StrArrSlice) -> ParsedCmd<StackingPlaceCmdArgs> {
    parseSpecificCmdArgs(StackingPlaceCmdArgs(rawArgs: args), args)
}

private func parseStackingIndex(i: PosArgParserInput) -> ParsedCliArgs<Int> {
    if let n = Int(i.arg), n >= 0 {
        return .succ(n, advanceBy: 1)
    }
    return .fail("Expected a non-negative integer, got '\(i.arg)'", advanceBy: 1)
}
