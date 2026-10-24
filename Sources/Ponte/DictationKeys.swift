import Carbon.HIToolbox
import Foundation

/// The keys a dictation answers to while it is in flight.
///
/// There is only one way to hear a bare key here. The HUD must never take focus — if it did, the
/// letters you are dictating over would go to the HUD instead of the app you are writing in — so it
/// cannot receive key events as a window does. A global hotkey needs no Accessibility permission and
/// works whatever is frontmost, so Esc and Return are registered as global hotkeys for the duration
/// of a dictation and released the moment it ends. That window is deliberately short: a bare Return
/// held down while idle would eat every return you press, in every app.
enum DictationKey: CaseIterable {
    case escape
    case enter
    case keypadEnter

    /// Carbon's virtual key codes — spelled out here rather than as raw values, because `kVK_*` are
    /// imported as `Int` and a raw value has to be a literal.
    var keyCode: UInt32 {
        switch self {
        case .escape: return UInt32(kVK_Escape)
        case .enter: return UInt32(kVK_Return)
        case .keypadEnter: return UInt32(kVK_ANSI_KeypadEnter)
        }
    }

    enum Meaning: String {
        case cancel
        case commit
    }

    var meaning: Meaning {
        switch self {
        case .escape: return .cancel
        case .enter, .keypadEnter: return .commit
        }
    }

    var hint: String {
        switch self {
        case .escape: return "Esc cancels"
        case .enter, .keypadEnter: return "Return finishes"
        }
    }

    /// One line for the tooltip and the menu, so the two cannot describe different keys.
    static var hints: String {
        var seen: [String] = []
        for key in allCases where !seen.contains(key.hint) { seen.append(key.hint) }
        return seen.joined(separator: " · ")
    }
}
