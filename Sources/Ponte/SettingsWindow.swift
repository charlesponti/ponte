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

private struct SidebarItem: View {
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

private struct PaneHeader: View {
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

private struct Line<Content: View>: View {
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

private struct Split: View {
    var body: some View { Rectangle().fill(UI.line).frame(height: 1).padding(.vertical, 18) }
}

private struct BoardButton: View {
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

private struct ToggleLine: View {
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
private struct KeyCap: View {
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

private struct KeyCaps: View {
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

// MARK: - Dictations

private struct DictationsPane: View {
    @ObservedObject var model: PonteWindowModel
    @ObservedObject var history: HistoryModel

    init(model: PonteWindowModel) {
        self.model = model
        self.history = model.history
    }

    private var stampFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }

    private var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }

    private func stamp(_ note: History.Note) -> String {
        guard let date = note.date else { return "—" }
        return Calendar.current.isDateInToday(date) ? stampFormatter.string(from: date)
                                                    : dayFormatter.string(from: date)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UI.ink3)
                TextField("Search the dictations", text: $history.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(UI.ink)
                Text("\(history.filtered.count) of \(history.notes.count)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UI.ink3)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            Rectangle().fill(UI.line).frame(height: 1)

            ScrollView { list }

            Rectangle().fill(UI.line).frame(height: 1)
            HStack(spacing: 8) {
                BoardButton(title: "Copy") { if let n = history.selected { history.copy(n) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                BoardButton(title: "Transcribe again") {
                    if let n = history.selected { history.retranscribe(n) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                BoardButton(title: "Show note") { if let n = history.selected { history.reveal(n) } }
                Spacer(minLength: 10)
                Text(history.message ?? defaultHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(UI.ink3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
        }
    }

    private var defaultHint: String {
        history.notes.isEmpty ? "Nothing dictated yet" : "Double-click a dictation to copy it"
    }

    @ViewBuilder private var list: some View {
        if UI.variant.groupsByDay {
            // Pinned day headers, so the date stops being a column repeated on every row.
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(DaySection.group(history.filtered)) { section in
                    Section {
                        ForEach(section.notes) { note in row(note) }
                    } header: {
                        dayHeader(section)
                    }
                }
            }
        } else {
            VStack(spacing: 0) {
                ForEach(history.filtered) { note in row(note) }
            }
        }
    }

    private func dayHeader(_ section: DaySection) -> some View {
        HStack(spacing: 8) {
            Text(section.title.uppercased())
                .font(.system(size: 10)).tracking(1.1)
                .foregroundStyle(UI.ink3)
            Text(section.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(UI.ink3.opacity(0.75))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 7)
        .background(UI.window)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UI.brass.opacity(0.22)).frame(height: 1)
        }
    }

    private func time(_ note: History.Note) -> String {
        guard let date = note.date else { return "—" }
        return stampFormatter.string(from: date)
    }

    @ViewBuilder private func row(_ note: History.Note) -> some View {
        if UI.variant.groupsByDay { stackedRow(note) } else { inlineRow(note) }
    }

    /// Time above the sentence; the duration is the length of a tick in the margin. Only real data — a longer take
    /// draws a longer tick, and nothing is invented.
    private func stackedRow(_ note: History.Note) -> some View {
        let selected = history.selection == note.id
        // Once a row is open, the prose *is* the row: repeating the sentence at 13 pt above it and the duration in
        // both the meta line and the footer says everything twice.
        let reading = selected && UI.variant.reads
        let seconds = CGFloat(DaySection.seconds(of: note))
        return HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(selected ? UI.accent : UI.brass.opacity(0.55))
                .frame(width: 2, height: 9 + min(17, seconds * 1.15))
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(time(note))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(UI.ink3)
                    if !reading, !note.duration.isEmpty {
                        Text(note.duration).font(.system(size: 11)).foregroundStyle(UI.ink3)
                    }
                }

                if reading {
                    self.reading(note)
                } else {
                    Text(note.title)
                        .font(.system(size: 13))
                        .foregroundStyle(UI.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(selected ? UI.selection.opacity(0.7) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { history.selection = note.id }
    }

    /// The dictation read as prose: serif at reading size, the facts underneath, the actions where they belong.
    private func reading(_ note: History.Note) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(note.text)
                .font(.system(size: 19, design: .serif))
                .lineSpacing(5)
                .foregroundStyle(UI.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let fresh = history.retranscribed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TRANSCRIBED AGAIN")
                        .font(.system(size: 10)).tracking(1.1)
                        .foregroundStyle(UI.ink3)
                    Text(fresh)
                        .font(.system(size: 17, design: .serif))
                        .lineSpacing(4)
                        .foregroundStyle(UI.ink2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Text([note.duration, note.engine].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(UI.ink3)
                Spacer(minLength: 8)
                BoardButton(title: "Copy") { history.copy(note) }
                BoardButton(title: "Transcribe again") { history.retranscribe(note) }
                BoardButton(title: "Show note") { history.reveal(note) }
            }
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
    }

    /// The shipped layout, for `plain`.
    private func inlineRow(_ note: History.Note) -> some View {
        let selected = history.selection == note.id
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(stamp(note))
                .font(.system(size: 12))
                .foregroundStyle(UI.ink3)
                .frame(width: 74, alignment: .leading)
            Text(note.duration.isEmpty ? "—" : note.duration)
                .font(.system(size: 11.5))
                .foregroundStyle(UI.ink3)
                .frame(width: 40, alignment: .trailing)
            Text(note.title)
                .font(.system(size: 13))
                .foregroundStyle(selected ? UI.accent : UI.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(selected ? UI.selection : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(UI.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            history.selection = note.id
            history.copy(note)
        }
        .onTapGesture {
            history.selection = note.id
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var model: PonteWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "General", sub: "What Ponte does when you press the key, and what it starts up with.")

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    Text("Hotkey").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    if model.recording {
                        Text("Press the new keys — Esc cancels")
                            .font(.system(size: 13))
                            .foregroundStyle(UI.accent)
                    } else {
                        KeyCaps(chord: model.hotKey)
                    }
                    Spacer(minLength: 8)
                    if !model.recording {
                        BoardButton(title: "Record…") { model.startRecording() }
                    }
                }
                .frame(minHeight: 34)
                .padding(.vertical, 7)

                if let note = model.recorderMessage {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(UI.amber)
                        .padding(.leading, 146)
                        .padding(.bottom, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .center, spacing: 14) {
                    Text("Dictation key")
                        .font(.system(size: 13)).foregroundStyle(UI.ink)
                        .frame(width: 132, alignment: .leading)
                    Picker("", selection: Binding(get: { model.hotKeyMode },
                                                  set: { model.setHotKeyMode($0) })) {
                        ForEach(HotKeyMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 34)
                .padding(.vertical, 7)

                HStack(alignment: .center, spacing: 14) {
                    Text("Microphone")
                        .font(.system(size: 13)).foregroundStyle(UI.ink)
                        .frame(width: 132, alignment: .leading)
                    Picker("", selection: Binding(get: { model.inputUID ?? "" },
                                                  set: { model.setInput($0) })) {
                        Text("System default — \(model.systemDefaultName)").tag("")
                        Divider()
                        ForEach(model.inputs) { input in
                            Text(input.name).tag(input.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 34)
                .padding(.vertical, 7)

                if model.micFellBack {
                    Text("\(model.pinnedName ?? "The chosen microphone") isn't connected — this take uses \(model.deviceName).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(UI.amber)
                        .padding(.leading, 146)
                        .padding(.bottom, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Split()

                ToggleLine(label: "Paste after", on: "On — at the cursor, in whatever you're writing",
                           off: "Off — the text is only copied", value: model.autoPaste, set: model.setAutoPaste)
                ToggleLine(label: "Keep audio", on: "On — takes are kept next to their notes",
                           off: "Off — takes are deleted once transcribed", value: model.keepAudio, set: model.setKeepAudio)
                ToggleLine(label: "At login", on: "On — Ponte starts with your Mac",
                           off: "Off — start it yourself", value: model.atLogin, set: model.setAtLogin)

                Split()

                HStack(alignment: .center, spacing: 14) {
                    Text("Vocabulary").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text(model.vocabularyLine).font(.system(size: 13)).foregroundStyle(UI.ink2)
                    Spacer(minLength: 8)
                    BoardButton(title: "Edit rules…", mint: true) { model.actions.editVocabulary() }
                }
                .frame(minHeight: 34)
                .padding(.vertical, 7)

                Text("Plain JSON you own, applied to every transcription. Whole words only, longest phrase first.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UI.ink3)
                    .padding(.leading, 146)
            }
            .frame(maxWidth: UI.contentMax, alignment: .leading)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.version) · \(model.model.label) on the Neural Engine · \(languageName)")
                Text("Your audio and text never leave the Mac. The only request Ponte makes is checking for its own updates.")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(UI.ink3)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var languageName: String {
        model.languages.first { $0.code == model.language }?.label ?? model.language
    }
}

// MARK: - Speech

private struct SpeechPane: View {
    @ObservedObject var model: PonteWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Speech", sub: "One engine, on the Neural Engine. Parakeet Ultra is the model that ships.")

            Text("MODEL").font(.system(size: 10)).tracking(1.1).foregroundStyle(UI.ink3).padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ParakeetModel.allCases), id: \.self) { m in
                    let installed = ParakeetEngine.shared.isInstalled(m)
                    Button { model.setModel(m) } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .strokeBorder(model.model == m ? UI.accent : UI.ink3, lineWidth: 1.4)
                                .background(Circle().fill(model.model == m ? UI.accent : .clear).padding(3))
                                .frame(width: 14, height: 14)
                            Text(m.label).font(.system(size: 13)).foregroundStyle(UI.ink)
                            Text(installed ? "· downloaded" : "· not downloaded")
                                .font(.system(size: 11.5)).foregroundStyle(UI.ink3)
                            Spacer(minLength: 8)
                            if !installed {
                                BoardButton(title: "Download") { model.actions.downloadModel(m) }
                            }
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: UI.contentMax, alignment: .leading)

            Split()

            Text("LANGUAGE").font(.system(size: 10)).tracking(1.1).foregroundStyle(UI.ink3).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.languages, id: \.code) { lang in
                    Button { model.setLanguage(lang.code) } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .strokeBorder(model.language == lang.code ? UI.accent : UI.ink3, lineWidth: 1.4)
                                .background(Circle().fill(model.language == lang.code ? UI.accent : .clear).padding(3))
                                .frame(width: 14, height: 14)
                            Text(lang.label).font(.system(size: 13)).foregroundStyle(UI.ink)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: UI.contentMax, alignment: .leading)

            Spacer(minLength: 12)
            Text("The model runs in this process on the Neural Engine. Nothing is uploaded, and the audio never leaves the Mac.")
                .font(.system(size: 11.5)).foregroundStyle(UI.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }
}

// MARK: - Updates

private struct UpdatesPane: View {
    @ObservedObject var model: PonteWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Updates", sub: "Ponte checks for its own updates. That request carries nothing about you.")

            VStack(alignment: .leading, spacing: 0) {
                ToggleLine(label: "Check for updates", on: "On — once a day, in the background",
                           off: "Off — check by hand", value: model.autoChecks, set: model.setAutoChecks)

                HStack(alignment: .center, spacing: 14) {
                    Text("Last check").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text(model.lastCheckLine).font(.system(size: 13)).foregroundStyle(UI.ink2)
                    Spacer(minLength: 8)
                    BoardButton(title: "Check now") { model.actions.checkForUpdates() }
                }
                .frame(minHeight: 34)
                .padding(.vertical, 7)

                if let update = model.updateAvailable {
                    Text("\(update) is available — the menu can install it.")
                        .font(.system(size: 12))
                        .foregroundStyle(UI.accent)
                        .padding(.leading, 146)
                        .padding(.top, 2)
                }

                Split()

                Line(label: "Version") { Text(model.version) }
                Text("The feed sends back an appcast and nothing else: no account, no identifier, and system profiling is off. A failed check says nothing at all.")
                    .font(.system(size: 11.5)).foregroundStyle(UI.ink3)
                    .padding(.leading, 146)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: UI.contentMax, alignment: .leading)

            Spacer(minLength: 12)
            Text("Sparkle installs the new build, verifies its signature, and relaunches Ponte.")
                .font(.system(size: 11.5)).foregroundStyle(UI.ink3)
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }
}

// MARK: - About

private struct AboutPane: View {
    @ObservedObject var model: PonteWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "About", sub: "Version, files, and the two permissions macOS asks for.")

            VStack(alignment: .leading, spacing: 0) {
                Line(label: "Ponte") { Text("\(model.version) · Apple Silicon") }
                Line(label: "Engine") { Text("\(model.model.label) on the Neural Engine") }

                Split()

                HStack(alignment: .center, spacing: 14) {
                    Text("Notes").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text("~/Documents/Ponte").font(.system(size: 13)).foregroundStyle(UI.ink2)
                    Spacer(minLength: 8)
                    BoardButton(title: "Open") { model.actions.openNotes() }
                }
                .frame(minHeight: 34)

                HStack(alignment: .center, spacing: 14) {
                    Text("Audio").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text(model.keepAudio ? "kept next to the notes" : "deleted after each transcription")
                        .font(.system(size: 13)).foregroundStyle(UI.ink2)
                    Spacer(minLength: 8)
                    BoardButton(title: "Open") { model.actions.openAudio() }
                }
                .frame(minHeight: 34)

                HStack(alignment: .center, spacing: 14) {
                    Text("Models").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text("in Application Support").font(.system(size: 13)).foregroundStyle(UI.ink2)
                    Spacer(minLength: 8)
                    BoardButton(title: "Reveal") { model.actions.revealModels() }
                }
                .frame(minHeight: 34)

                Split()

                HStack(alignment: .center, spacing: 14) {
                    Text("Microphone").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text(model.micGranted ? "granted" : "not granted")
                        .font(.system(size: 13))
                        .foregroundStyle(model.micGranted ? UI.ink2 : UI.amber)
                    Spacer(minLength: 8)
                    if !model.micGranted { BoardButton(title: "Grant…") { model.actions.grantMicrophone() } }
                }
                .frame(minHeight: 34)

                HStack(alignment: .center, spacing: 14) {
                    Text("Pasting").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text(model.accessibilityGranted ? "granted — text is typed at the cursor"
                                                   : "not granted — text goes to the clipboard instead")
                        .font(.system(size: 13))
                        .foregroundStyle(model.accessibilityGranted ? UI.ink2 : UI.amber)
                    Spacer(minLength: 8)
                    if model.accessibilityGranted {
                        BoardButton(title: "Repair…") { model.actions.repairPermissions() }
                    } else {
                        BoardButton(title: "Grant…") { model.actions.grantAccessibility() }
                    }
                }
                .frame(minHeight: 34)

                Text("Repair clears a grant left behind by an old build and asks again — the fix when the pane says granted and pasting still does not work.")
                    .font(.system(size: 11.5)).foregroundStyle(UI.ink3)
                    .padding(.leading, 146)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: UI.contentMax, alignment: .leading)

            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Text("charlesponti.github.io/ponte").font(.system(size: 11.5)).foregroundStyle(UI.ink3)
                BoardButton(title: "Open page") { model.actions.openSite() }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 18)
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
