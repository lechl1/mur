import AppKit
import Common

/// mur — the windows the user focused, most recent last. Every window mur
/// focuses (`setFocus`) goes to the top; a closed window just drops out.
///
/// A close never moves focus by itself: macOS can't tell a window the user
/// closed from one another process closed (depot quitting an app it
/// reinstalls, a script), so an automatic pop would jump focus around at
/// another program's whim. Going back is the user's call instead:
/// `focus-back-and-forth` focuses the most recent window that is still
/// there, other than the focused one — after a close, the window before
/// it; pressed again, back where it was.
struct FocusStack: Equatable {
    static let limit = 64

    /// Most recent last.
    private(set) var windowIds: [UInt32] = []

    mutating func push(_ windowId: UInt32) {
        windowIds.removeAll { $0 == windowId }
        windowIds.append(windowId)
        if windowIds.count > Self.limit { windowIds.removeFirst(windowIds.count - Self.limit) }
    }

    mutating func remove(_ windowId: UInt32) {
        windowIds.removeAll { $0 == windowId }
    }

    /// The most recent window other than `current` that `canFocus`. Forgets
    /// windows that no longer exist; skips (but keeps) ones that exist and
    /// can't take focus now (minimized, hidden).
    mutating func previous(
        before current: UInt32?,
        exists: (UInt32) -> Bool,
        canFocus: (UInt32) -> Bool,
    ) -> UInt32? {
        windowIds.removeAll { !exists($0) }
        return windowIds.last { $0 != current && canFocus($0) }
    }
}

@MainActor var focusStack = FocusStack()

/// The window `focus-back-and-forth` goes to.
@MainActor func previouslyFocusedWindow() -> Window? {
    let id = focusStack.previous(
        before: focus.windowOrNil?.windowId,
        exists: { Window.get(byId: $0) != nil },
        canFocus: { Window.get(byId: $0)?.canTakeFocusBack == true },
    )
    return id.flatMap { Window.get(byId: $0) }
}

extension Window {
    @MainActor fileprivate var canTakeFocusBack: Bool {
        guard let parent, toLiveFocusOrNil() != nil else { return false }
        return switch parent.cases {
            case .tilingContainer, .workspace: true
            case .macosPopupWindowsContainer, .macosMinimizedWindowsContainer,
                 .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer: false
        }
    }
}
