import Carbon.HIToolbox
import Foundation

/// Global hotkey via the Carbon hotkey API — works system-wide without needing
/// Accessibility permission for the *key press* itself.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var installed = false
    private static var actions: [UInt32: () -> Void] = [:]
    /// Key-*up* handlers, for hold-to-talk. Separate from `actions` on purpose: toggle mode ignores a release, so a
    /// chord registered without one must not gain behaviour it did not ask for.
    private static var releases: [UInt32: () -> Void] = [:]
    private static var handlerRef: EventHandlerRef?
    private static var releaseHandlerRef: EventHandlerRef?
    private static var nextID: UInt32 = 1

    private(set) var keyCode: UInt32
    private(set) var modifiers: UInt32

    init?(keyCode: UInt32, modifiers: UInt32,
          action: @escaping () -> Void,
          onRelease: (() -> Void)? = nil) {
        Self.installHandlerIfNeeded()
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.id = Self.nextID
        Self.nextID += 1
        Self.actions[id] = action
        if let onRelease { Self.releases[id] = onRelease }

        let hotKeyID = EventHotKeyID(signature: OSType(0x564E4F54), id: id) // 'VNOT'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            vlog("hotkey registration failed status=\(status) key=\(keyCode) mods=\(modifiers)")
            Self.actions[id] = nil
            return nil
        }
        vlog("hotkey registered key=\(keyCode) mods=\(modifiers)")
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        GlobalHotKey.actions[id] = nil
        GlobalHotKey.releases[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hkID)
            if err == noErr, let action = GlobalHotKey.actions[hkID.id] {
                DispatchQueue.main.async { action() }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }, 1, &spec, nil, &handlerRef)

        // The key-up, which Carbon delivers as its own event kind.
        var releaseSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                        eventKind: UInt32(kEventHotKeyReleased))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hkID)
            if err == noErr, let release = GlobalHotKey.releases[hkID.id] {
                vlog("hotkey: key-up received id=\(hkID.id)")
                DispatchQueue.main.async { release() }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }, 1, &releaseSpec, nil, &releaseHandlerRef)
    }
}

// MARK: - Human-readable hotkey description

enum HotKeySpec {
    // Default: ⌥⌘Space
    static let defaultKeyCode = UInt32(kVK_Space)
    static let defaultModifiers = UInt32(optionKey | cmdKey)

    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += name(for: keyCode)
        return s
    }

    static func name(for keyCode: UInt32) -> String {
        let map: [Int: String] = [
            kVK_Space: "Space",
            kVK_ANSI_V: "V",
            kVK_ANSI_R: "R",
            kVK_ANSI_D: "D",
            kVK_ANSI_N: "N",
            kVK_ANSI_1: "1",
            kVK_ANSI_2: "2",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F9: "F9", kVK_F13: "F13",
        ]
        return map[Int(keyCode)] ?? "key\(keyCode)"
    }
}
