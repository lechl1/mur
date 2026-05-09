// mur — phase 2 CLI command. Move the focused window one tile in a
// cardinal direction. Lane axis (left/right) clamps at the grid bounds.
// Slot axis (up/down) clamps at 0 going up; going down past the last
// slot APPENDS a new slot to the lane.
public struct GridMoveCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .gridMove,
        allowInConfig: true,
        help: grid_move_help_generated,
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
