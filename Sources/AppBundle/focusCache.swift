@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    // mur — an app started in the background (a depot relaunch) doesn't
    // take focus: stay put and give macOS's focus back (BackgroundLaunch).
    if let nativeFocused, nativeFocused.windowId != lastKnownNativeFocusedWindowId,
       declinesBackgroundLaunchFocus(nativeFocused)
    {
        focus.windowOrNil?.nativeFocus()
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}
