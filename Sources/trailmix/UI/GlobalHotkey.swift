import AppKit
import Carbon

/// One system-wide keyboard shortcut, registered with Carbon's
/// `RegisterEventHotKey`. It fires whichever app is in front, needs no
/// Accessibility grant (unlike an `NSEvent` global monitor), and is the
/// mechanism every menu-bar recorder uses for start/stop.
///
/// The combination comes from `hotkey` in the config file, written like
/// `"cmd+shift+5"`: any of `cmd`, `shift`, `alt` (or `option`), `ctrl`, then
/// one key: a letter, a digit, `f1`…`f12` or `space`. `"none"` turns it off.
///
/// A combination macOS already owns (⇧⌘3, ⇧⌘4, ⇧⌘5 for screenshots, ⌘Space
/// for Spotlight) is taken by the system first: registration succeeds but the
/// key never reaches us until that system shortcut is switched off in
/// System Settings › Keyboard › Keyboard Shortcuts.
final class GlobalHotkey: @unchecked Sendable {
    struct Combo: Equatable, Sendable {
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let cocoaModifiers: NSEvent.ModifierFlags
        /// What `NSMenuItem.keyEquivalent` wants: the bare key, lowercase.
        let keyEquivalent: String
        /// How it reads in a menu or a log line: ⇧⌘5, ⌃⌥F5.
        let display: String

        /// `"cmd+shift+5"` → a combo; nil for `"none"`, `""`, or anything not
        /// understood. Letters use the ANSI key codes, so a Dvorak or AZERTY
        /// layout gets the key at the QWERTY position of that letter, which
        /// is what every other hotkey API on macOS does too.
        static func parse(_ spec: String) -> Combo? {
            let tokens = spec.lowercased().split(whereSeparator: { "+- ".contains($0) }).map(String.init)
            guard !tokens.isEmpty, !["none", "off", "false"].contains(tokens[0]) else { return nil }
            var carbon: UInt32 = 0
            var cocoa: NSEvent.ModifierFlags = []
            var glyphs = ""
            var key: String?
            for token in tokens {
                switch token {
                case "cmd", "command", "⌘": carbon |= UInt32(cmdKey); cocoa.insert(.command)
                case "shift", "⇧": carbon |= UInt32(shiftKey); cocoa.insert(.shift)
                case "alt", "option", "opt", "⌥": carbon |= UInt32(optionKey); cocoa.insert(.option)
                case "ctrl", "control", "⌃": carbon |= UInt32(controlKey); cocoa.insert(.control)
                default:
                    guard key == nil else { return nil }
                    key = token
                }
            }
            guard let key, let code = keyCodes[key], carbon != 0 else { return nil }
            // Standard glyph order, the one System Settings uses.
            if cocoa.contains(.control) { glyphs += "⌃" }
            if cocoa.contains(.option) { glyphs += "⌥" }
            if cocoa.contains(.shift) { glyphs += "⇧" }
            if cocoa.contains(.command) { glyphs += "⌘" }
            let label = key.hasPrefix("f") && key.count > 1 ? key.uppercased() : (key == "space" ? "Space" : key.uppercased())
            return Combo(
                keyCode: code,
                carbonModifiers: carbon,
                cocoaModifiers: cocoa,
                keyEquivalent: key == "space" ? " " : (key.hasPrefix("f") && key.count > 1 ? "" : key),
                display: glyphs + label
            )
        }

        private static let keyCodes: [String: UInt32] = [
            "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D),
            "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F), "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H),
            "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
            "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O), "p": UInt32(kVK_ANSI_P),
            "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R), "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
            "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
            "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
            "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
            "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
            "f1": UInt32(kVK_F1), "f2": UInt32(kVK_F2), "f3": UInt32(kVK_F3), "f4": UInt32(kVK_F4),
            "f5": UInt32(kVK_F5), "f6": UInt32(kVK_F6), "f7": UInt32(kVK_F7), "f8": UInt32(kVK_F8),
            "f9": UInt32(kVK_F9), "f10": UInt32(kVK_F10), "f11": UInt32(kVK_F11), "f12": UInt32(kVK_F12),
            "space": UInt32(kVK_Space),
        ]
    }

    let combo: Combo
    private let handler: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Registers immediately. nil when Carbon refuses, which in practice
    /// means another process already holds that exact combination.
    init?(combo: Combo, handler: @escaping @MainActor () -> Void) {
        self.combo = combo
        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers application-target events on the main thread.
                MainActor.assumeIsolated { hotkey.handler() }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else { return nil }

        // The signature and id only have to be unique within this process.
        let id = EventHotKeyID(signature: OSType(0x54524D58) /* 'TRMX' */, id: 1)
        guard RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr,
            hotKeyRef != nil
        else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
