// mur — explicit grow / shrink of the focused window's LANE extent:
// column width in landscape, row height in portrait (the lane axis flips
// with the monitor). `stacking-resize` is positional — the arrow pointing
// towards the centre grows — which makes a single "make it bigger" key
// impossible. This command is unambiguous: `grow` always makes the column
// wider (row taller in portrait), `shrink` always smaller.
public enum StackingSizeDelta: String, CaseIterable, Equatable, Sendable {
    case grow
    case shrink

    public var signum: Int { self == .grow ? +1 : -1 }
}

public struct StackingResizeLaneCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .stackingResizeLane,
        allowInConfig: true,
        help: stacking_resize_lane_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [
            newMandatoryPosArgParser(\.delta, parseStackingSizeDeltaArg, placeholder: StackingSizeDelta.unionLiteral),
        ],
    )

    public var delta: Lateinit<StackingSizeDelta> = .uninitialized
}
