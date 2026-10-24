import AppKit

/// Which state the app is in, as far as the menu bar is concerned.
enum AppState: String, CaseIterable {
    case idle, starting, recording, working
}

/// What the menu bar wears in each state. Kept out of the app delegate so the command line can
/// render exactly what the bar is handed, and so a test can assert it: an image that is not a
/// template is drawn as-is, and a black glyph on a dark menu bar is invisible.
enum StatusIcon {
    /// The momentary states keep their system glyphs — "recording" is worth more than branding while
    /// it is happening, and the orb is on screen in the HUD at that point anyway. At rest the bar
    /// wears the app's own mark.
    static func symbol(for state: AppState) -> String? {
        switch state {
        case .idle: return nil
        case .starting: return "record.circle.fill"
        case .recording: return "record.circle.fill"
        case .working: return "waveform"
        }
    }

    static func tint(for state: AppState) -> NSColor? {
        switch state {
        case .idle: return nil
        case .starting, .working: return .systemOrange
        case .recording: return .systemRed
        }
    }

    /// The image the bar is given, always as a template so `contentTintColor` can colour it.
    static func image(for state: AppState) -> NSImage {
        let image = symbol(for: state)
            .flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Ponte") }
            // 16 pt, against the 15 pt system glyphs: the ring reads a shade smaller than a filled
            // symbol at the same size, and matching them stops the item growing when you record.
            ?? IconRenderer.menuBarImage(MenuBarMark.chosen, pointSize: 16)
        image.isTemplate = true
        return image
    }
}
