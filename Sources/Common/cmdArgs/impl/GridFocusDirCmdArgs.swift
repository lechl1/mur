// mur — phase 2 CLI command. Shift focus to the spatial neighbor in
// the given cardinal direction, walking the GRID (not the tree).
//
// Axis mapping by orientation:
//   landscape  →  left/right move along lane axis,
//                 up/down  move along slot axis (within current lane).
//   portrait   →  left/right move along slot axis (within current lane),
//                 up/down  move along lane axis.
//
// "Nearest" means: smallest lane-delta (or slot-delta) in the requested
// direction. Ties on distance are broken by zOrder — the topmost
// candidate wins.
public struct GridFocusDirCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .gridFocusDir,
        allowInConfig: true,
        help: grid_focus_dir_help_generated,
        flags: [
            "--workspace": workspaceSubArgParser(),
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
