import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// MARK: - Palette
//
// The board's values, in one place. Ponte is a menu-bar utility with its own look, not a document app: the sidebar
// selection is its mint rather than the system accent, because everything else the app draws is mint too.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum UI {
    // Colours come from the theme so the whole window can change register without touching a call site.
    static var theme: WindowTheme { .current }
    static var window: Color { theme.window }
    static var sidebar: Color { theme.sidebar }
    static var ink: Color { theme.ink }
    static var ink2: Color { theme.ink2 }
    static var ink3: Color { theme.ink3 }
    static var accent: Color { theme.accent }
    static var brass: Color { theme.brass }
    /// Warning: the calm amber, never the accent. Refusals are amber, failures are red.
    static let amber = Color(hex: 0xE0B25A)
    static var line: Color { theme.line }
    static var hairline: Color { theme.hairline }
    static var selection: Color { theme.accentSoft }
    static var control: Color { theme.control }
    static var controlBorder: Color { theme.controlBorder }

    static let sidebarWidth: CGFloat = 176
    /// The inset that makes the sidebar and the content pane one system: same top, same bottom, same radius, and a
    /// gutter between them.
    static let gutter: CGFloat = 10
    static let panelRadius: CGFloat = 14

    /// Which composition the window draws. Read from `windowVariant` on every build, so the flag works without a
    /// relaunch and a capture loop can walk the directions in one session.
    static var variant: WindowVariant { .current }

    /// Liquid Glass exists from macOS 26 and the package floor is macOS 15, so every use is gated. Centralised so no
    /// call site has to remember which build it is on.
    /// Tinted: untinted glass takes its colour from whatever is behind it, which read as a washed lavender panel
    /// that had nothing to do with the app.
    static var glassTint: Color { theme.glassTint }

    static var glassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    static let size = CGSize(width: 860, height: 560)
    static let contentMax: CGFloat = 560
}

// MARK: - Panes

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case dictations, general, speech, updates, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictations: return "Dictations"
        case .general: return "General"
        case .speech: return "Speech"
        case .updates: return "Updates"
        case .about: return "About"
        }
    }

    static var settings: [Pane] { [.general, .speech, .updates, .about] }
}

// MARK: - Actions owned by the app

/// What the window can ask the app to do. Closures rather than a reference to `AppDelegate`, which is not
/// main-actor isolated: the window owns presentation, the app owns behaviour.
struct WindowActions {
    var beginHotKeyRecording: () -> Void = {}
    var endHotKeyRecording: () -> Void = {}
    var changeHotKey: (HotKeyChord) -> Bool = { _ in false }
    var setModel: (ParakeetModel) -> Void = { _ in }
    var downloadModel: (ParakeetModel) -> Void = { _ in }
    var openNotes: () -> Void = {}
    var openAudio: () -> Void = {}
    var revealModels: () -> Void = {}
    var editVocabulary: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var grantMicrophone: () -> Void = {}
    var grantAccessibility: () -> Void = {}
    var repairPermissions: () -> Void = {}
    var openSite: () -> Void = {}
}

// MARK: - Model

@MainActor
final class PonteWindowModel: ObservableObject {
    @Published var pane: Pane = .dictations
    @Published var variant: WindowVariant = .current
    let history = HistoryModel()

    @Published var hotKey = HotKeyChord.default
    @Published var hotKeyMode = Settings.hotKeyModeSetting
    @Published var recording = false
    @Published var recorderMessage: String?

    @Published var autoPaste = Settings.autoPaste
    @Published var keepAudio = Settings.keepAudio
    @Published var atLogin = false
    @Published var model = Settings.parakeetModel
    @Published var language = Settings.language
    @Published var autoChecks = true

    @Published var message: String?
    @Published var updateAvailable: String?
    @Published var vocabCount = 0
    @Published var deviceName = "—"
    @Published var inputs: [AudioInput] = []
    @Published var inputUID: String?
    @Published var inputCount = 0
    @Published var systemDefaultName = "the system input"
    /// A pin that is no longer connected: the window says so instead of quietly recording from something else.
    @Published var micFellBack = false
    @Published var pinnedName: String?
    @Published var languages: [(code: String, label: String)] = []
    @Published var micGranted = false
    @Published var accessibilityGranted = false

    var actions = WindowActions()
    private var monitor: Any?

    var version: String { "Ponte \(AppPaths.Version.display)" }

    var micLine: String { "System default — \(deviceName)" }

    var vocabularyLine: String {
        vocabCount == 0 ? "No rules — the engine's own spelling" : "\(vocabCount) rule\(vocabCount == 1 ? "" : "s")"
    }

    var lastCheckLine: String {
        guard let date = UserDefaults.standard.object(forKey: "SULastCheckTime") as? Date else {
            return "not checked yet"
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Re-read everything from disk and defaults. Called every time the window comes up, so a file edited by hand
    /// or a hotkey changed from the terminal is reflected rather than remembered.
    func refresh() {
        // A fresh install has no values at all, and every getter below reads through `UserDefaults`: without this,
        // the window shows auto-paste and keep-audio as off when they are on. Registering is idempotent, so the
        // window can do it rather than depending on the order the app happened to start in.
        Settings.registerDefaults()
        variant = .current
        history.reload()
        hotKeyMode = Settings.hotKeyModeSetting
        hotKey = HotKeyChord(
            keyCode: Settings.hotKey(SettingKey.hotKeyCode, default: HotKeySpec.defaultKeyCode),
            modifiers: Settings.hotKey(SettingKey.hotKeyMods, default: HotKeySpec.defaultModifiers)
        )
        autoPaste = Settings.autoPaste
        keepAudio = Settings.keepAudio
        model = Settings.parakeetModel
        language = Settings.language
        autoChecks = (UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool) ?? true
        atLogin = SMAppService.mainApp.status == .enabled
        vocabCount = Vocabulary.load().rules.count
        // What is actually live is the system default unless a pin is connected — the same resolution the recorder
        // does, so the window cannot disagree with the take.
        inputs = AudioInputs.available()
        let defaultUID = AudioInputs.systemDefaultUID()
        systemDefaultName = inputs.first { $0.uid == defaultUID }?.name ?? "the system input"
        let resolved = AudioInputs.resolve(pinned: Settings.inputDeviceUID, available: inputs, defaultUID: defaultUID)
        deviceName = resolved.input?.name ?? "no input device"
        micFellBack = resolved.fellBack
        pinnedName = Settings.inputDeviceUID
        inputUID = Settings.inputDeviceUID
        inputCount = inputs.count
        micGranted = Recorder.isAuthorized
        accessibilityGranted = AXIsProcessTrusted()
    }

    // Setters that persist immediately — there is no Save button, and a control that needs one is a worse control.
    func setAutoPaste(_ value: Bool) { autoPaste = value; Settings.autoPaste = value }
    func setKeepAudio(_ value: Bool) { keepAudio = value; Settings.keepAudio = value }

    func setAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "could not change login item: \(error.localizedDescription)"
        }
        atLogin = SMAppService.mainApp.status == .enabled
    }

    func setAutoChecks(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "SUEnableAutomaticChecks")
        autoChecks = value
    }

    func setHotKeyMode(_ mode: HotKeyMode) {
        Settings.hotKeyModeSetting = mode
        hotKeyMode = mode
    }

    func setInput(_ uid: String) {
        Settings.inputDeviceUID = uid.isEmpty ? nil : uid
        refresh()   // re-resolve, so the row immediately tells the truth about what is live
    }

    func setLanguage(_ code: String) { Settings.language = code; language = code }
    func setModel(_ m: ParakeetModel) { actions.setModel(m); model = m }

    // MARK: the recorder

    /// Record a chord without the current one interfering: the live hotkey is unregistered first, because otherwise
    /// pressing the chord you already have would start a dictation instead of being captured.
    func startRecording() {
        guard !recording else { return }
        recorderMessage = nil
        actions.beginHotKeyRecording()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.capture(event)
            return nil   // swallow it: the chord being recorded must not reach anything else
        }
    }

    private func capture(_ event: NSEvent) {
        let modifiers = HotKeyChord.carbonModifiers(from: event.modifierFlags)
        if Int(event.keyCode) == kVK_Escape && modifiers == 0 {
            finishRecording(nil)
            return
        }
        let chord = HotKeyChord(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        if let why = chord.rejection {
            recorderMessage = why          // stay in recording mode so another chord can be tried
            return
        }
        finishRecording(chord)
    }

    func finishRecording(_ chord: HotKeyChord?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        guard let chord else {
            recorderMessage = nil
            actions.endHotKeyRecording()   // put the old chord back
            return
        }
        if actions.changeHotKey(chord) {
            hotKey = chord
            recorderMessage = nil
            message = "hotkey is now \(chord.display)"
        } else {
            recorderMessage = "\(chord.display) is taken by another app — kept \(hotKey.display)"
            actions.endHotKeyRecording()
        }
    }

    /// Called when the window closes mid-record, so a closed window never leaves the app without a hotkey.
    func cancelRecordingIfNeeded() {
        if recording { finishRecording(nil) }
    }
}

// MARK: - Root

struct PonteRootView: View {
    @ObservedObject var model: PonteWindowModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            Group {
                // Dictations has its own scrolling list; the settings panes are plain stacks, and a pane taller than
                // the window (thirteen languages and four models) was clipping at the bottom and pushing its own
                // header off the top. Every pane scrolls.
                switch model.pane {
                case .dictations:
                    DictationsPane(model: model)
                case .general:
                    ScrollView { GeneralPane(model: model) }
                case .speech:
                    ScrollView { SpeechPane(model: model) }
                case .updates:
                    ScrollView { UpdatesPane(model: model) }
                case .about:
                    ScrollView { AboutPane(model: model) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(UI.window)
            .clipShape(RoundedRectangle(cornerRadius: UI.panelRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: UI.panelRadius, style: .continuous)
                    .stroke(UI.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            // Same vertical inset as the sidebar, plus a gutter in front of it: the two panes sit on one line and
            // read as two objects rather than one rectangle cut in half.
            .padding(.leading, UI.gutter)
            .padding(.trailing, UI.gutter)
            .padding(.vertical, UI.gutter)
        }
        .background(UI.variant.floatsContent ? (UI.theme.backdrop ?? Color(hex: 0x141310).opacity(0.94)) : .clear)
        .background(UI.glassAvailable ? Color.clear : UI.window)
        .onDisappear { model.cancelRecordingIfNeeded() }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: PonteWindowModel

    var body: some View {
        if UI.variant.usesRail { rail } else { labels }
    }

    /// Icons only: the labels cost about 120 pt of width, and the content can use it.
    private var rail: some View {
        VStack(spacing: 4) {
            Image(nsImage: StatusIcon.image(for: .idle))
                .resizable().scaledToFit()
                .frame(width: 18, height: 18)
                .padding(.top, UI.glassAvailable ? 26 : 10)
                .padding(.bottom, 8)

            ForEach(Pane.allCases) { pane in
                Button { model.pane = pane } label: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(model.pane == pane ? UI.accent : UI.ink2)
                        .frame(width: 32, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(model.pane == pane ? UI.selection : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pane.title)
            }

            Spacer(minLength: 8)
        }
        .frame(width: 56)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(panelBackground)
        .padding(.leading, UI.glassAvailable ? UI.gutter : 0)
        .padding(.vertical, UI.glassAvailable ? UI.gutter : 0)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 0) {
            if UI.variant.showsMark {
                // The app's own menu-bar mark, not a drawing of it.
                Image(nsImage: StatusIcon.image(for: .idle))
                    .resizable().scaledToFit()
                    .frame(width: 18, height: 18)
                    .padding(.leading, 16)
                    .padding(.top, UI.glassAvailable ? 26 : 10)
                    .padding(.bottom, 4)
            }

            SidebarItem(title: "Dictations", count: model.history.notes.count,
                        selected: model.pane == .dictations) { model.pane = .dictations }
                // With a full-size content view the window's traffic lights sit over the panel's top edge.
                .padding(.top, UI.variant.showsMark ? 8 : (UI.glassAvailable ? 30 : 12))

            Text("SETTINGS")
                .font(.system(size: 10))
                .tracking(1.1)
                .foregroundStyle(UI.ink3)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 5)

            ForEach(Pane.settings) { pane in
                SidebarItem(title: pane.title, count: nil, selected: model.pane == pane) { model.pane = pane }
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppPaths.Version.display)
                Text("Your audio and text\nnever leave the Mac.")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(UI.ink3)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: UI.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        // Apple's rule: glass is the navigation layer, and sidebars float in it. The content pane beside this keeps
        // its own solid surface so text contrast never depends on the wallpaper.
        .background(panelBackground)
        .overlay(alignment: .trailing) {
            // With the material there is no seam to draw: the panel edge does that job.
            if !UI.glassAvailable { Rectangle().fill(UI.line).frame(width: 1) }
        }
        .padding(.leading, UI.glassAvailable ? UI.gutter : 0)
        .padding(.vertical, UI.glassAvailable ? UI.gutter : 0)
    }

    @ViewBuilder private var panelBackground: some View {
        if #available(macOS 26.0, *) {
            // `.interactive()` because every row here is clickable: the spec says interaction feedback belongs to
            // glass used as a background for interactive controls.
            Color.clear
                .glassEffect(UI.theme.glassStyle == .clear
                             ? .clear.tint(UI.glassTint).interactive()
                             : .regular.tint(UI.glassTint).interactive(),
                             in: .rect(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(UI.hairline, lineWidth: 1)
                )
        } else {
            UI.sidebar
        }
    }
}

struct SidebarItem: View {
    let title: String
    let count: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? UI.accent : UI.ink2)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? UI.accent.opacity(0.8) : UI.ink3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? UI.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

// MARK: - Shared pieces

struct PaneHeader: View {
    let title: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(UI.ink)
            Text(sub).font(.system(size: 12)).foregroundStyle(UI.ink3)
        }
        .padding(.bottom, 18)
    }
}

struct Line<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(UI.ink)
                .frame(width: 132, alignment: .leading)
            content
                .font(.system(size: 13))
                .foregroundStyle(UI.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .frame(minHeight: 34)
    }
}

struct Split: View {
    var body: some View { Rectangle().fill(UI.line).frame(height: 1).padding(.vertical, 18) }
}

struct BoardButton: View {
    let title: String
    var mint: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(mint ? UI.accent : UI.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(mint ? UI.accent.opacity(0.10) : UI.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(mint ? UI.accent.opacity(0.45) : UI.controlBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct ToggleLine: View {
    let label: String
    let on: String
    let off: String
    let value: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
            Text(value ? on : off).font(.system(size: 13)).foregroundStyle(UI.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: Binding(get: { value }, set: set))
                .toggleStyle(.switch)
                .tint(UI.accent)
                .labelsHidden()
        }
        .padding(.vertical, 7)
        .frame(minHeight: 34)
    }
}

/// One keycap, drawn as an object: a wall below the face, a lit top edge, and an engraved legend.
///
/// The wall is the whole trick — a key that is only a rounded rectangle reads as a label in a box, however carefully
/// it is coloured. Three points of wall plus a highlight is what makes the eye see something pressable.
struct KeyCap: View {
    let legend: String
    var wide = false

    private let corner: CGFloat = 6
    private let wallDepth: CGFloat = 2.5

    var body: some View {
        let face = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack(alignment: .top) {
            // the wall: the side of the key, below the face
            face.fill(UI.theme.keyWall)
                .frame(height: 26 + wallDepth)
                .overlay(face.stroke(UI.theme.keyEdge.opacity(0.7), lineWidth: 1))

            // the face
            face.fill(
                    LinearGradient(colors: [UI.theme.keyFace, UI.theme.keyFace.opacity(0.92)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(height: 26)
                .overlay(
                    // the lit top edge an old cap has, and its lower shadow
                    face.strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(UI.theme.isDark ? 0.14 : 0.85),
                                                Color.white.opacity(0.0)],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
                )
                .overlay(face.stroke(UI.theme.keyEdge, lineWidth: 1))

            Text(legend)
                .font(.system(size: 12.5, weight: .medium))
                .tracking(legend.count > 2 ? 0 : 0.4)
                .foregroundStyle(UI.theme.keyLegend)
                // engraved, not printed: the glyph sits in the cap rather than on it
                .shadow(color: UI.theme.isDark ? Color.black.opacity(0.55) : Color.white.opacity(0.85),
                        radius: 0, x: 0, y: 1)
                .frame(height: 26)
                .padding(.horizontal, wide ? 12 : 0)
        }
        .frame(minWidth: wide ? 52 : 27)
        .frame(height: 26 + wallDepth)
        .padding(.top, 1)   // room for the drop shadow below the wall
        .shadow(color: Color.black.opacity(UI.theme.isDark ? 0.45 : 0.26), radius: 1.4, y: 1.4)
    }
}

struct KeyCaps: View {
    let chord: HotKeyChord

    private var caps: [String] {
        var out: [String] = []
        let m = chord.modifiers
        if m & UInt32(controlKey) != 0 { out.append("⌃") }
        if m & UInt32(optionKey) != 0 { out.append("⌥") }
        if m & UInt32(shiftKey) != 0 { out.append("⇧") }
        if m & UInt32(cmdKey) != 0 { out.append("⌘") }
        out.append(HotKeySpec.name(for: chord.keyCode))
        return out
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                KeyCap(legend: cap, wide: cap.count > 2)
            }
        }
    }
}

// MARK: - The window

/// The one window: dictations first, then the settings that used to be a fourteen-item menu.
///
/// Made once and reused, `isReleasedWhenClosed = false` so state survives closing it, and constructed lazily inside
/// the main actor — `AppDelegate` is not isolated, and a window built off the main thread crashes in ways that read
/// like a SwiftUI bug.
@MainActor
final class PonteWindow {
    private var window: NSWindow?
    let model = PonteWindowModel()

    func show(pane: Pane = .dictations) {
        if window == nil { build() }
        model.pane = pane
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    private func build() {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: UI.size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Ponte"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 760, height: 500)
        // The material resolves against the window's appearance, so this is the theme's job: a dark scrim and light
        // glass in a light window would cancel each other out.
        w.appearance = NSAppearance(named: UI.theme.isDark ? .darkAqua : .aqua)
        if #available(macOS 26.0, *) {
            // Glass needs something behind it to sample. An opaque window gives it flat grey, so the window is made
            // see-through and the glass reaches under the title bar; only the content pane paints a surface.
            w.isOpaque = false
            w.backgroundColor = .clear
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            // A transparent title bar over a full-size content view is no longer a drag handle on its own.
            w.isMovableByWindowBackground = true
            vlog("window: Liquid Glass chrome on (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
        } else {
            w.backgroundColor = NSColor(srgbRed: 19 / 255, green: 19 / 255, blue: 21 / 255, alpha: 1)
        }
        let hosted = NSHostingView(rootView: PonteRootView(model: model))
        if #available(macOS 26.0, *) {
            // Glass needs something behind it, but "clear" is the wrong something: a fully transparent window lets
            // another app's text be read through the title bar. The backdrop is what Apple's own windows use — the
            // desktop is diffused, never legible — and the glass then samples that instead of raw pixels.
            let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: UI.size))
            backdrop.material = .underWindowBackground
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            // A dark scrim over the blur. Without it the strip above the glass panel measured (75,76,70) against
            // the panel's (15,15,17) — a milky band above a black panel, which reads as two surfaces fighting.
            let scrim = NSView(frame: backdrop.bounds)
            scrim.autoresizingMask = [.width, .height]
            scrim.wantsLayer = true
            // The theme's own backdrop, always — not only in `studio`. Otherwise the band above the panels is a raw
            // frosted blur, which read as a grey step above a parchment window.
            let ground = UI.theme.backdrop ?? (UI.theme.isDark ? Color.black.opacity(0.55) : Color.white.opacity(0.55))
            let resolved = NSColor(ground).usingColorSpace(.sRGB) ?? NSColor(white: UI.theme.isDark ? 0 : 1, alpha: 0.55)
            scrim.layer?.backgroundColor = resolved.cgColor
            backdrop.addSubview(scrim)

            hosted.frame = backdrop.bounds
            hosted.autoresizingMask = [.width, .height]
            backdrop.addSubview(hosted)
            w.contentView = backdrop
        } else {
            w.contentView = hosted
        }
        w.center()
        window = w
    }
}
