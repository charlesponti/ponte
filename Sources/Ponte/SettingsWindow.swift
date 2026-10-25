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
    static let window = Color(hex: 0x131315)
    static let sidebar = Color(hex: 0x1A1A1D)
    static let ink = Color.white.opacity(0.96)
    static let ink2 = Color.white.opacity(0.62)
    static let ink3 = Color.white.opacity(0.40)
    static let mint = Color(hex: 0x66D4CF)
    static let amber = Color(hex: 0xE0B25A)
    static let line = Color.white.opacity(0.075)
    static let hairline = Color.white.opacity(0.035)
    static let selection = Color(hex: 0x66D4CF).opacity(0.13)
    static let control = Color.white.opacity(0.08)
    static let controlBorder = Color.white.opacity(0.13)

    static let sidebarWidth: CGFloat = 176
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
    let history = HistoryModel()

    @Published var hotKey = HotKeyChord.default
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
        history.reload()
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
        deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "no input device"
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
                switch model.pane {
                case .dictations: DictationsPane(model: model)
                case .general: GeneralPane(model: model)
                case .speech: SpeechPane(model: model)
                case .updates: UpdatesPane(model: model)
                case .about: AboutPane(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(UI.window)
        }
        .background(UI.window)
        .onDisappear { model.cancelRecordingIfNeeded() }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: PonteWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarItem(title: "Dictations", count: model.history.notes.count,
                        selected: model.pane == .dictations) { model.pane = .dictations }
                .padding(.top, 12)

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
        .background(UI.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(UI.line).frame(width: 1) }
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
                    .foregroundStyle(selected ? UI.mint : UI.ink2)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? UI.mint.opacity(0.8) : UI.ink3)
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
                .foregroundStyle(mint ? UI.mint : UI.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(mint ? UI.mint.opacity(0.10) : UI.control)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(mint ? UI.mint.opacity(0.45) : UI.controlBorder, lineWidth: 1)
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
                .tint(UI.mint)
                .labelsHidden()
        }
        .padding(.vertical, 7)
        .frame(minHeight: 34)
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
        HStack(spacing: 5) {
            ForEach(caps, id: \.self) { cap in
                Text(cap)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(UI.ink)
                    .frame(minWidth: 26, minHeight: 26)
                    .padding(.horizontal, cap.count > 2 ? 7 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(hex: 0x242428))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(UI.controlBorder, lineWidth: 1))
                    )
            }
        }
    }
}

// MARK: - Dictations

private struct DictationsPane: View {
    @ObservedObject var model: PonteWindowModel
    @ObservedObject var history: HistoryModel
    @FocusState private var focused: Bool

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

            // A plain VStack, not a LazyVStack: a few dozen rows cost nothing to build, and the lazy one does not
            // materialise in an offscreen `ImageRenderer` pass — which would leave the window unrenderable and
            // therefore unverifiable.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(history.filtered) { note in
                        row(note)
                    }
                }
            }
            .focusable()
            .focused($focused)
            .onKeyPress { press in
                guard press.key == .return, let note = history.selected else { return .ignored }
                if press.modifiers.contains(.command) { history.retranscribe(note) } else { history.copy(note) }
                return .handled
            }

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
        .onAppear { focused = true }
    }

    private var defaultHint: String {
        history.notes.isEmpty ? "Nothing dictated yet" : "Double-click a dictation to copy it"
    }

    private func row(_ note: History.Note) -> some View {
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
                .foregroundStyle(selected ? UI.mint : UI.ink)
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
                            .foregroundStyle(UI.mint)
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

                Line(label: "Microphone") {
                    Text(model.micLine)
                }
                Text("A pinned microphone arrives with the settings work in #14 — today Ponte records from the system input.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UI.ink3)
                    .padding(.leading, 146)
                    .padding(.bottom, 6)

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
                                .strokeBorder(model.model == m ? UI.mint : UI.ink3, lineWidth: 1.4)
                                .background(Circle().fill(model.model == m ? UI.mint : .clear).padding(3))
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
                                .strokeBorder(model.language == lang.code ? UI.mint : UI.ink3, lineWidth: 1.4)
                                .background(Circle().fill(model.language == lang.code ? UI.mint : .clear).padding(3))
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
                        .foregroundStyle(UI.mint)
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
        w.backgroundColor = NSColor(srgbRed: 19 / 255, green: 19 / 255, blue: 21 / 255, alpha: 1)
        w.contentView = NSHostingView(rootView: PonteRootView(model: model))
        w.center()
        window = w
    }
}
