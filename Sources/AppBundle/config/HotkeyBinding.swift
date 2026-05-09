import AppKit
import Common
import Foundation
import HotKey

@MainActor private var hotkeys: [String: HotKey] = [:]
/// Per-binding press-and-hold auto-repeat tasks. Cancelled on key-up
/// (and also on resetHotKeys to drop any in-flight repeats when the
/// config reloads).
@MainActor private var hotkeyRepeatTasks: [String: Task<Void, Never>] = [:]

@MainActor func resetHotKeys() {
    // Explicitly unregister all hotkeys. We cannot always rely on destruction of the HotKey object to trigger
    // unregistration because we might be running inside a hotkey handler that is keeping its HotKey object alive.
    for (_, key) in hotkeys {
        key.isEnabled = false
    }
    hotkeys = [:]
    for (_, task) in hotkeyRepeatTasks { task.cancel() }
    hotkeyRepeatTasks = [:]
}

extension HotKey {
    var isEnabled: Bool {
        get { !isPaused }
        set {
            if isEnabled != newValue {
                isPaused = !newValue
            }
        }
    }
}

@MainActor var activeMode: String? = mainModeId
@MainActor func activateMode(_ targetMode: String?) async throws {
    let targetBindings = targetMode.flatMap { config.modes[$0] }?.bindings ?? [:]
    for binding in targetBindings.values where !hotkeys.keys.contains(binding.descriptionWithKeyCode) {
        // mur — stacking-move (move) and stacking-resize (bloom resize) both
        // auto-repeat on press-and-hold. stacking-move repeats are useful
        // at the screen edge where the command falls through to the
        // same resize logic as stacking-resize, and elsewhere they keep
        // ramping the alternation / chained extract → shrink. Other
        // commands fire once per press.
        let isRepeatable = binding.commands.contains {
            $0 is StackingMoveCommand || $0 is StackingResizeCommand
        }
        let bindingKey = binding.descriptionWithKeyCode
        let fire: @MainActor () -> Void = {
            Task {
                if let activeMode {
                    broadcastEvent(.bindingTriggered(
                        mode: activeMode,
                        binding: binding.descriptionWithKeyNotation,
                    ))
                    try await runLightSession(.hotkeyBinding, .checkServerIsEnabledOrDie()) { () throws in
                        _ = try await config.modes[activeMode]?.bindings[bindingKey]?.commands
                            .runCmdSeq(.defaultEnv, .emptyStdin)
                    }
                }
            }
        }
        let hotkey = HotKey(
            key: binding.keyCode,
            modifiers: binding.modifiers,
            keyDownHandler: {
                Task { @MainActor in
                    fire()
                    guard isRepeatable else { return }
                    hotkeyRepeatTasks[bindingKey]?.cancel()
                    hotkeyRepeatTasks[bindingKey] = Task { @MainActor in
                        // Initial hold delay before auto-repeat kicks in
                        // (matches typical OS key-repeat).
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        if Task.isCancelled { return }
                        // ~20Hz repeat (50ms) — fast enough to feel like
                        // a continuous resize, slow enough to debounce
                        // multiple ladder steps comfortably.
                        while !Task.isCancelled {
                            fire()
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                    }
                }
            },
            keyUpHandler: isRepeatable ? {
                Task { @MainActor in
                    hotkeyRepeatTasks[bindingKey]?.cancel()
                    hotkeyRepeatTasks[bindingKey] = nil
                }
            } : nil,
        )
        hotkeys[bindingKey] = hotkey
    }
    for (binding, key) in hotkeys {
        key.isEnabled = targetBindings.keys.contains(binding)
    }
    let oldMode = activeMode
    activeMode = targetMode
    if oldMode != targetMode {
        broadcastEvent(.modeChanged(mode: targetMode))
        if !config.onModeChanged.isEmpty {
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.onModeChanged, token) {
                _ = try await config.onModeChanged.runCmdSeq(.defaultEnv, .emptyStdin)
            }
        }
    }
}

struct HotkeyBinding: Equatable, Sendable {
    let modifiers: NSEvent.ModifierFlags
    let keyCode: Key
    let commands: [any Command]
    let descriptionWithKeyCode: String
    let descriptionWithKeyNotation: String

    init(_ modifiers: NSEvent.ModifierFlags, _ keyCode: Key, _ commands: [any Command], descriptionWithKeyNotation: String) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.commands = commands
        self.descriptionWithKeyCode = modifiers.isEmpty
            ? keyCode.toString()
            : modifiers.toString() + "-" + keyCode.toString()
        self.descriptionWithKeyNotation = descriptionWithKeyNotation
    }

    static func == (lhs: HotkeyBinding, rhs: HotkeyBinding) -> Bool {
        lhs.modifiers == rhs.modifiers &&
            lhs.keyCode == rhs.keyCode &&
            lhs.descriptionWithKeyCode == rhs.descriptionWithKeyCode &&
            zip(lhs.commands, rhs.commands).allSatisfy { $0.equals($1) }
    }
}

func parseBindings(_ raw: Json, _ backtrace: ConfigBacktrace, _ errors: inout [ConfigParseError], _ mapping: [String: Key]) -> [String: HotkeyBinding] {
    guard let rawTable = raw.asDictOrNil else {
        errors += [expectedActualTypeError(expected: .table, actual: raw.tomlType, backtrace)]
        return [:]
    }
    var result: [String: HotkeyBinding] = [:]
    for (binding, rawCommand): (String, Json) in rawTable {
        let backtrace = backtrace + .key(binding)
        let binding = parseBinding(binding, backtrace, mapping)
            .flatMap { modifiers, key -> ParsedConfig<HotkeyBinding> in
                parseCommandOrCommands(rawCommand).toParsedConfig(backtrace).map {
                    HotkeyBinding(modifiers, key, $0, descriptionWithKeyNotation: binding)
                }
            }
            .getOrNil(appendErrorTo: &errors)
        if let binding {
            if result.keys.contains(binding.descriptionWithKeyCode) {
                errors.append(.semantic(backtrace, "'\(binding.descriptionWithKeyCode)' Binding redeclaration"))
            }
            result[binding.descriptionWithKeyCode] = binding
        }
    }
    return result
}

func parseBinding(_ raw: String, _ backtrace: ConfigBacktrace, _ mapping: [String: Key]) -> ParsedConfig<(NSEvent.ModifierFlags, Key)> {
    let rawKeys = raw.split(separator: "-")
    let modifiers: ParsedConfig<NSEvent.ModifierFlags> = rawKeys.dropLast()
        .mapAllOrFailure {
            modifiersMap[String($0)].orFailure(.semantic(backtrace, "Can't parse modifiers in '\(raw)' binding"))
        }
        .map { NSEvent.ModifierFlags($0) }
    let key: ParsedConfig<Key> = rawKeys.last.flatMap { mapping[String($0)] }
        .orFailure(.semantic(backtrace, "Can't parse the key in '\(raw)' binding"))
    return modifiers.flatMap { modifiers -> ParsedConfig<(NSEvent.ModifierFlags, Key)> in
        key.flatMap { key -> ParsedConfig<(NSEvent.ModifierFlags, Key)> in
            .success((modifiers, key))
        }
    }
}
