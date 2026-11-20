import AppKit
import Common

/// mur — the windows the user focused, most recent last. When the focused
/// window closes (or its app quits), focus pops back to the window that had
/// it before — on whichever workspace that is — instead of whatever macOS or
/// the workspace's own history picks.
///
/// macOS moves focus first: by the time mur notices a window is gone, it has
/// usually already followed macOS to some other window (the app's next
/// window, the next app). So every native focus move records the stack as it
/// was just before (`noteNativeSwitch`). If the window focus moved away from
/// dies within `fallbackWindow`, that move was macOS's fallback, not the
/// user's choice, and the stack is rolled back to the snapshot. A window that
/// had only just opened when it got focus keeps it: that is an app handing
/// over from a splash or a dialog, and the new window is what the user wants.
struct FocusStack: Equatable {
    static let limit = 64
    static let fallbackWindow: TimeInterval = 2

    struct NativeSwitch: Equatable {
        let from: UInt32
        var before: [UInt32]
        let at: Date
    }

    /// Most recent last.
    private(set) var windowIds: [UInt32] = []
    private(set) var lastSwitch: NativeSwitch? = nil
    private(set) var popPending = false
    private var registeredAt: [UInt32: Date] = [:]

    var top: UInt32? { windowIds.last }

    mutating func push(_ windowId: UInt32) {
        windowIds.removeAll { $0 == windowId }
        windowIds.append(windowId)
        if windowIds.count > Self.limit { windowIds.removeFirst(windowIds.count - Self.limit) }
    }

    mutating func noteRegistered(_ windowId: UInt32, at now: Date) {
        registeredAt[windowId] = now
    }

    /// macOS moved focus from `from` to `to` (nil: the app kept focus with
    /// no window). Call before the stack records the new focus.
    mutating func noteNativeSwitch(from: UInt32, to: UInt32?, at now: Date) {
        if let to, let born = registeredAt[to], now.timeIntervalSince(born) <= Self.fallbackWindow {
            lastSwitch = nil // a freshly opened window keeps the focus it was given
            return
        }
        lastSwitch = NativeSwitch(from: from, before: windowIds, at: now)
    }

    /// `windowId` is gone. Marks a pop when it was the focused window, or the
    /// one macOS moved focus away from just before it died.
    mutating func remove(_ windowId: UInt32, at now: Date) {
        registeredAt.removeValue(forKey: windowId)
        if let lastSwitch, lastSwitch.from == windowId, now.timeIntervalSince(lastSwitch.at) <= Self.fallbackWindow {
            windowIds = lastSwitch.before
            self.lastSwitch = nil
            popPending = true
        } else if top == windowId {
            popPending = true
        }
        windowIds.removeAll { $0 == windowId }
        lastSwitch?.before.removeAll { $0 == windowId }
    }

    /// After a batch of closes: the window focus pops to, if a pop is due.
    /// Forgets windows that no longer exist; skips (but keeps) ones that
    /// exist and can't take focus now (minimized, hidden).
    mutating func takePopTarget(exists: (UInt32) -> Bool, canFocus: (UInt32) -> Bool) -> UInt32? {
        guard popPending else { return nil }
        popPending = false
        windowIds.removeAll { !exists($0) }
        return windowIds.last(where: canFocus)
    }
}

@MainActor var focusStack = FocusStack()

extension FocusStack {
    @MainActor static func windowRegistered(_ windowId: UInt32) {
        focusStack.noteRegistered(windowId, at: .now)
    }

    /// Whether a pop is now due, so the caller leaves focus to `popFocusAfterClose`.
    @MainActor static func windowDied(_ windowId: UInt32) -> Bool {
        focusStack.remove(windowId, at: .now)
        return focusStack.popPending
    }
}

/// Run after windows were garbage-collected: focus the window the closed one
/// took focus from.
@MainActor func popFocusAfterClose() {
    let target = focusStack.takePopTarget(
        exists: { Window.get(byId: $0) != nil },
        canFocus: { Window.get(byId: $0)?.canTakeFocusBack == true },
    )
    guard let target, let window = Window.get(byId: target), window != focus.windowOrNil else { return }
    if window.focusWindow() {
        window.nativeFocus()
    }
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
