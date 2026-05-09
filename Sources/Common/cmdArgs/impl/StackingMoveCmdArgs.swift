// mur — phase 2 CLI command. Move the focused window in the given
// cardinal direction by swapping with its neighbour. Lane axis swaps
// whole columns (lane weights and slot assignments move together); slot
// axis swaps two rows within the focused lane. Carries every other
// window in the swapped column/row along for the ride and preserves the
// lane / slot weights of each side.
public struct StackingMoveCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .stackingMove,
        allowInConfig: true,
        help: stacking_move_help_generated,
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
