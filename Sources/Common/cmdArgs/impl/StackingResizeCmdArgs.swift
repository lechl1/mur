// mur — phase 2 CLI command. Bloom-resize the focused window's lane / slot
// along a fraction ladder (1/16 ↔ ... ↔ 1/2 ↔ ... ↔ 15/16). Other lanes
// (or slots within the lane) absorb / donate weight proportionally. The
// window itself stays put — this is a pure resize, not a move.
public struct StackingResizeCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .stackingResize,
        allowInConfig: true,
        help: stacking_resize_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [
            newMandatoryPosArgParser(\.direction, parseCardinalDirectionArg, placeholder: CardinalDirection.unionLiteral),
        ],
    )

    public var direction: Lateinit<CardinalDirection> = .uninitialized

    public init(rawArgs: [String], direction: CardinalDirection) {
        self.commonState = .init(rawArgs.slice)
        self.direction = .initialized(direction)
    }
}
