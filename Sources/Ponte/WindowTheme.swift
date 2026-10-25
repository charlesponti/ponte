import SwiftUI

/// The window's colours, as a themed set rather than constants.
///
/// `maison` is a luxury palette after the great Paris saddler: an ebony ground, ivory ink rather than white, brass
/// hairlines, cognac for depth, and a single saturated orange that is allowed to appear **only** for state — the
/// selected take, the live tick, a running job. A luxury palette spends almost nothing; that restraint is the whole
/// effect. Nothing here claims any affiliation, it is a colour system in that register.
struct WindowTheme {
    let name: String
    let window: Color
    let sidebar: Color
    let glassTint: Color
    let ink: Color
    let ink2: Color
    let ink3: Color
    let accent: Color
    let accentSoft: Color
    let brass: Color
    let line: Color
    let hairline: Color
    let control: Color
    let controlBorder: Color
    /// Warmth laid over the frosted window backdrop, so the gaps around the glass belong to the palette too.
    let backdrop: Color?
    /// Drives the window's appearance (so the material resolves dark or light), and the scrim's colour.
    let isDark: Bool

    static var current: WindowTheme {
        WindowTheme(rawValue: UserDefaults.standard.string(forKey: "windowTheme") ?? "")
    }

    enum Keys { static let theme = "windowTheme" }

    let rawValue: String

    init(rawValue: String) {
        switch rawValue {
        case "maison": self = .maison
        case "parchment", "light": self = .parchment
        case "mint": self = .mint
        default: self = .parchment
        }
    }

    /// Ponte's original: near-black, cold white ink, mint.
    static let mint = WindowTheme(
        rawValue: "mint",
        window: Color(hex: 0x131315),
        sidebar: Color(hex: 0x1A1A1D),
        glassTint: Color(red: 0.055, green: 0.055, blue: 0.062),
        ink: Color.white.opacity(0.96),
        ink2: Color.white.opacity(0.62),
        ink3: Color.white.opacity(0.40),
        accent: Color(hex: 0x66D4CF),
        accentSoft: Color(hex: 0x66D4CF).opacity(0.13),
        brass: Color.white.opacity(0.30),
        line: Color.white.opacity(0.075),
        hairline: Color.white.opacity(0.035),
        control: Color.white.opacity(0.08),
        controlBorder: Color.white.opacity(0.13),
        backdrop: nil,
        isDark: true
    )

    /// Ebony, ivory, brass, cognac, and one orange that means "here".
    static let maison = WindowTheme(
        rawValue: "maison",
        window: Color(hex: 0x1B1712),
        sidebar: Color(hex: 0x171310),
        glassTint: Color(hex: 0x171310),
        // Ivory, not white: a warm off-white is what makes a dark ground read as lacquer rather than as a terminal.
        ink: Color(hex: 0xF4EEE4).opacity(0.96),
        ink2: Color(hex: 0xEFE7DA).opacity(0.58),
        ink3: Color(hex: 0xD8C9B4).opacity(0.40),
        accent: Color(hex: 0xE9762B),
        accentSoft: Color(hex: 0xE9762B).opacity(0.11),
        brass: Color(hex: 0xC2A268),
        line: Color(hex: 0xF4EEE4).opacity(0.075),
        hairline: Color(hex: 0xC2A268).opacity(0.14),
        control: Color(hex: 0xF4EEE4).opacity(0.06),
        controlBorder: Color(hex: 0xC2A268).opacity(0.22),
        backdrop: Color(hex: 0x141109).opacity(0.94),
        isDark: true
    )

    /// The same maison register in daylight: parchment rather than white, ebony ink, and the orange deepened until it
    /// can carry text on a light ground — the bright one fails there, which is why light-mode accents are always
    /// darker than they look in the design.
    static let parchment = WindowTheme(
        rawValue: "parchment",
        window: Color(hex: 0xF7F2E8),
        sidebar: Color(hex: 0xF2ECDF),
        glassTint: Color(hex: 0xF2ECDF),
        ink: Color(hex: 0x1D1A16).opacity(0.92),
        ink2: Color(hex: 0x1D1A16).opacity(0.66),
        ink3: Color(hex: 0x1D1A16).opacity(0.46),
        accent: Color(hex: 0xB8491A),
        accentSoft: Color(hex: 0xC2571B).opacity(0.10),
        brass: Color(hex: 0x8A6A3B),
        line: Color(hex: 0x1D1A16).opacity(0.10),
        hairline: Color(hex: 0x8A6A3B).opacity(0.24),
        control: Color(hex: 0x1D1A16).opacity(0.05),
        controlBorder: Color(hex: 0x8A6A3B).opacity(0.28),
        backdrop: Color(hex: 0xF7F2E8).opacity(0.94),
        isDark: false
    )

    init(rawValue: String, window: Color, sidebar: Color, glassTint: Color, ink: Color, ink2: Color, ink3: Color,
         accent: Color, accentSoft: Color, brass: Color, line: Color, hairline: Color, control: Color,
         controlBorder: Color, backdrop: Color?, isDark: Bool) {
        self.rawValue = rawValue
        self.name = rawValue
        self.window = window
        self.sidebar = sidebar
        self.glassTint = glassTint
        self.ink = ink
        self.ink2 = ink2
        self.ink3 = ink3
        self.accent = accent
        self.accentSoft = accentSoft
        self.brass = brass
        self.line = line
        self.hairline = hairline
        self.control = control
        self.controlBorder = controlBorder
        self.backdrop = backdrop
        self.isDark = isDark
    }
}
