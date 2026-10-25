import AppKit
import Carbon.HIToolbox
import Foundation

/// A global hotkey: one key plus the modifiers held with it.
///
/// Pure by design — the window records one of these and `AppDelegate` tries to register it, so everything that can
/// be decided without Carbon is decided here, where it can be tested.
struct HotKeyChord: Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// ⌥⌘Space, the chord Ponte has shipped with.
    static let `default` = HotKeyChord(keyCode: UInt32(kVK_Space),
                                      modifiers: UInt32(optionKey | cmdKey))

    /// The modifiers Carbon understands. Shift is deliberately *not* enough on its own.
    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    /// The modifiers that make a chord safe: with one of these held, the key is not how anyone types a character.
    static let strongMask = UInt32(cmdKey | optionKey | controlKey)

    var display: String { HotKeySpec.describe(keyCode: keyCode, modifiers: modifiers) }

    /// Why this chord cannot be used, or nil when it can.
    ///
    /// The rule is not cosmetic. A bare letter as a global hotkey is taken away from *every other app* on the
    /// machine, and so is ⇧ alone — ⇧A is how you type a capital A. Only ⌘, ⌥ or ⌃ (or a bare function key, which
    /// types nothing) make a chord that can live system-wide without being noticed.
    var rejection: String? {
        if Self.functionKeys.contains(Int(keyCode)) { return nil }
        if modifiers & Self.strongMask == 0 {
            return "Add ⌘, ⌥ or ⌃ — a bare key would be taken from every app."
        }
        if keyCode == 0 { return "That key cannot be used as a shortcut." }
        return nil
    }

    var isUsable: Bool { rejection == nil }

    /// Carbon's modifier mask from an AppKit event.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    /// Function keys, which are safe on their own because they produce no character.
    static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
}
