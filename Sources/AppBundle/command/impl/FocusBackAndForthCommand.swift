import AppKit
import Common

struct FocusBackAndForthCommand: Command {
    let args: FocusBackAndForthCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        // mur — the focus stack, not the one previous focus: after a close,
        // the window before it (FocusStack).
        switch previouslyFocusedWindow() {
            case let window?: .from(bool: window.focusWindow())
            case nil: .fail(io.err("No other recently focused window"))
        }
    }
}
