// mur — phase 2 CLI command. Swap the focused window's column / row
// with the neighbour in the given cardinal direction. Lane axis swaps
// whole columns (lane weights and slot assignments move together);
// slot axis swaps two rows within the focused lane.
public struct GridSwapCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .gridSwap,
        allowInConfig: true,
        help: grid_swap_help_generated,
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
