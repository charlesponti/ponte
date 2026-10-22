import AppKit
import AVFoundation
import CoreGraphics
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private let hud = HUD()
    private let downloader = ModelDownloader()
    private var hotKey: GlobalHotKey?

    private enum State { case idle, starting, recording, working }
    private var state: State = .idle

    /// A single physical press can deliver two hotkey events (key down/up, or key
    /// repeat). Swallow the duplicate so one press never spawns two recorders.
    private var lastHotKeyAt = Date.distantPast
    private let hotKeyDebounce: TimeInterval = 0.25

    private var lastTranscript: String?
    private var progressItem: NSMenuItem?

    private let languages: [(code: String, label: String)] = [
        ("en", "English"), ("auto", "Auto-detect"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("pl", "Polish"), ("ru", "Russian"), ("uk", "Ukrainian"), ("tr", "Turkish"),
        ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
    ]

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        vlog("--- launch pid=\(ProcessInfo.processInfo.processIdentifier) model=\(Settings.model) whisper=\(Whisper.binary()?.path ?? "MISSING") models=\(Whisper.installedModels())")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        recorder.onMeter = { [weak self] level, peak in
            self?.hud.pushLevel(level, peak: peak)
        }

        let code = Settings.hotKey(SettingKey.hotKeyCode, default: HotKeySpec.defaultKeyCode)
        let mods = Settings.hotKey(SettingKey.hotKeyMods, default: HotKeySpec.defaultModifiers)
        hotKey = GlobalHotKey(keyCode: code, modifiers: mods) { [weak self] in self?.toggle() }
        if hotKey == nil {
            Shell.notify("VoiceNote", "Hotkey \(HotKeySpec.describe(keyCode: code, modifiers: mods)) is taken — use the menu icon.")
        }

        downloader.onProgress = { [weak self] text in
            self?.progressItem?.title = text
            self?.hudProgress(text)
        }
        downloader.onFinish = { result in
            switch result {
            case .success(let url):
                Settings.model = url.lastPathComponent
                Shell.notify("VoiceNote", "Model ready: \(url.lastPathComponent)")
            case .failure(let error):
                Shell.notify("VoiceNote", "Download failed: \(error.localizedDescription)")
            }
        }

        if Whisper.binary() == nil {
            Shell.notify("VoiceNote", "whisper-cli not found — run: brew install whisper-cpp")
        }

        // Ask for the microphone once at first launch instead of surprising you
        // mid-sentence on the first hotkey press.
        if !UserDefaults.standard.bool(forKey: "didPromptMic") {
            UserDefaults.standard.set(true, forKey: "didPromptMic")
            Recorder.requestPermission { granted in
                vlog("first-run microphone prompt answered granted=\(granted)")
            }
        }

        // Warm the ASR engine so the first dictation doesn't sit through CoreML's
        // one-time Neural Engine programme specialisation (~20 s).
        if Settings.engine == .parakeet {
            let model = Settings.parakeetModel
            DispatchQueue.global(qos: .utility).async {
                do {
                    try ParakeetEngine.shared.preload(model: model)
                } catch {
                    vlog("preload failed: \(error.localizedDescription)")
                }
            }
        }

        // Proof-of-life: record where the menu bar item actually landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let button = self.statusItem.button else {
                vlog("STATUS ITEM MISSING")
                return
            }
            if let window = button.window {
                let f = window.frame
                vlog("status item frame x=\(Int(f.origin.x)) y=\(Int(f.origin.y)) w=\(Int(f.width)) h=\(Int(f.height)) visible=\(window.isVisible)")
            } else {
                vlog("status item has no window")
            }
        }
    }

    // MARK: - Recording flow

    @objc private func toggle() {
        let now = Date()
        if now.timeIntervalSince(lastHotKeyAt) < hotKeyDebounce {
            vlog("duplicate hotkey event ignored (\(String(format: "%.0f", now.timeIntervalSince(lastHotKeyAt) * 1000))ms)")
            return
        }
        lastHotKeyAt = now

        switch state {
        case .idle: startRecording()
        case .starting: vlog("hotkey ignored — recording is already starting")
        case .recording: stopAndTranscribe()
        case .working: NSSound.beep()
        }
    }

    private func startRecording() {
        // Set this synchronously: the permission callback is async, and a second
        // event landing in that window would otherwise start a second recorder.
        state = .starting
        updateIcon()

        Recorder.requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.state = .idle
                self.updateIcon()
                self.hud.showError("Microphone access denied — System Settings ▸ Privacy")
                Shell.notify("VoiceNote", "Microphone access denied. Grant it in System Settings ▸ Privacy & Security ▸ Microphone.")
                return
            }
            // A stop may have arrived while the permission call was in flight.
            guard case .starting = self.state else {
                vlog("start aborted — state changed to \(self.state) while waiting for permission")
                return
            }
            do {
                _ = try self.recorder.start()
            } catch {
                self.state = .idle
                self.updateIcon()
                self.hud.showError("Could not start recording")
                vlog("record start failed: \(error)")
                return
            }
            self.state = .recording
            self.updateIcon()
            self.hud.beginRecording()
        }
    }

    private func stopAndTranscribe() {
        let elapsed = recorder.elapsed
        guard let url = recorder.stop() else {
            state = .idle
            updateIcon()
            return
        }
        state = .working
        updateIcon()
        hud.showWorking()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try AsrEngine.transcribe(wav: url) { message in
                    DispatchQueue.main.async { self.hudProgress(message) }
                }
                DispatchQueue.main.async {
                    self.finish(text: result.text, took: result.seconds, audio: url,
                                elapsed: elapsed, engine: result.engine)
                }
            } catch {
                vlog("transcribe failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.state = .idle
                    self.updateIcon()
                    self.hud.showError("Transcription failed")
                    Shell.notify("VoiceNote", error.localizedDescription)
                    self.cleanUp(audio: url)
                }
            }
        }
    }

    private func finish(text: String, took: Double, audio: URL, elapsed: TimeInterval, engine: String) {
        state = .idle
        updateIcon()

        guard !text.isEmpty else {
            hud.showError("Heard nothing")
            vlog("empty transcript, audio kept at \(audio.path)")
            return
        }

        lastTranscript = text
        Transcriber.save(transcript: text, audio: audio, elapsed: elapsed, took: took, engine: engine)
        vlog(String(format: "transcribed %.1fs audio in %.1fs -> %d chars [%@]", elapsed, took, text.count, engine))

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        if Settings.autoPaste, AXIsProcessTrusted() {
            pasteAtCursor()
            // Just the outcome: the times are in the log and the note's frontmatter for anyone who
            // wants them, and a pill that reports two numbers needs a legend to be readable.
            hud.showDone("Pasted ✓")
        } else {
            // Never raise the system Accessibility dialog here: it fired at the end of
            // every dictation. Fall back to the clipboard and say so quietly.
            hud.showDone("Copied to clipboard ✓")
            if Settings.autoPaste { noteAccessibilityOnce() }
        }

        cleanUp(audio: audio)
    }

    private func cleanUp(audio: URL) {
        guard !Settings.keepAudio else { return }
        try? FileManager.default.removeItem(at: audio)
    }

    /// Simulate ⌘V in whatever app is frontmost.
    private func pasteAtCursor() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private var hasPromptedAccessibility = false
    private func promptAccessibility() {
        guard !hasPromptedAccessibility else { return }
        hasPromptedAccessibility = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Quiet, once-per-launch notice instead of a modal system prompt.
    private var hasNotedAccessibility = false
    private func noteAccessibilityOnce() {
        guard !hasNotedAccessibility else { return }
        hasNotedAccessibility = true
        vlog("auto-paste unavailable — Accessibility not granted for this build")
        Shell.notify("VoiceNote",
                     "Auto-paste needs Accessibility: System Settings ▸ Privacy & Security ▸ Accessibility. Until then the text goes to the clipboard.")
    }

    /// Progress arrives as prose ("Downloading Parakeet models… 43% (12/20 files)").
    /// The HUD has room for the number, so show that; otherwise just the orb.
    private func hudProgress(_ message: String) {
        if let range = message.range(of: #"(\d{1,3})%"#, options: .regularExpression),
           let percent = Int(message[range].dropLast()) {
            hud.showDownload(percent: percent)
        } else {
            hud.showWorking()
        }
    }

    private func updateIcon() {
        let (symbol, tint): (String, NSColor?) = {
            switch state {
            case .idle: return ("mic.fill", nil)
            case .starting: return ("record.circle.fill", .systemOrange)
            case .recording: return ("record.circle.fill", .systemRed)
            case .working: return ("waveform", .systemOrange)
            }
        }()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoiceNote")
        image?.isTemplate = (tint == nil)
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = tint
        statusItem?.button?.toolTip = "VoiceNote — \(HotKeySpec.describe(keyCode: hotKey?.keyCode ?? HotKeySpec.defaultKeyCode, modifiers: hotKey?.modifiers ?? HotKeySpec.defaultModifiers))"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shortcut = HotKeySpec.describe(keyCode: hotKey?.keyCode ?? HotKeySpec.defaultKeyCode,
                                           modifiers: hotKey?.modifiers ?? HotKeySpec.defaultModifiers)

        switch state {
        case .idle:
            menu.addItem(item("Start Recording", #selector(toggle), shortcut))
        case .starting:
            let i = item("Starting…", nil, nil)
            i.isEnabled = false
            menu.addItem(i)
        case .recording:
            menu.addItem(item("Stop & Transcribe", #selector(toggle), shortcut))
        case .working:
            let i = item("Transcribing…", nil, nil)
            i.isEnabled = false
            menu.addItem(i)
        }

        let copy = item("Copy Last Transcript", #selector(copyLast), nil)
        copy.isEnabled = lastTranscript != nil
        menu.addItem(copy)

        menu.addItem(.separator())
        menu.addItem(item("Open Notes Folder", #selector(openNotes), nil))
        menu.addItem(item("Open Audio Folder", #selector(openAudio), nil))

        menu.addItem(.separator())
        menu.addItem(modelMenu())
        menu.addItem(languageMenu())
        menu.addItem(engineMenu())

        menu.addItem(.separator())
        menu.addItem(check("Auto-paste into frontmost app", Settings.autoPaste, #selector(toggleAutoPaste)))
        menu.addItem(check("Keep audio files", Settings.keepAudio, #selector(toggleKeepAudio)))
        menu.addItem(loginItem())

        menu.addItem(.separator())
        menu.addItem(permissionsMenu())
        menu.addItem(.separator())

        let dev = NSMenuItem(title: "Mic: \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "none")", action: nil, keyEquivalent: "")
        dev.isEnabled = false
        menu.addItem(dev)

        let quit = NSMenuItem(title: "Quit VoiceNote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func modelMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        if let progress = downloader.activeName, downloader.isBusy {
            let p = NSMenuItem(title: "downloading \(progress)…", action: nil, keyEquivalent: "")
            p.isEnabled = false
            sub.addItem(p)
            progressItem = p
            sub.addItem(.separator())
        } else {
            progressItem = nil
        }

        let installed = Whisper.installedModels()
        for name in installed {
            sub.addItem(check(name, Settings.model == name, #selector(selectModel(_:)), represented: name))
        }
        if installed.isEmpty {
            let i = NSMenuItem(title: "no models downloaded yet", action: nil, keyEquivalent: "")
            i.isEnabled = false
            sub.addItem(i)
        }

        let missing = Whisper.downloadable.filter { !installed.contains($0.name) }
        if !missing.isEmpty {
            sub.addItem(.separator())
            for m in missing {
                sub.addItem(item("Download \(m.label)", #selector(downloadModel(_:)), nil, represented: m.name))
            }
        }
        sub.addItem(.separator())
        sub.addItem(item("Reveal Models Folder", #selector(openModels), nil))

        parent.submenu = sub
        return parent
    }

    private func engineMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        for kind in AsrEngineKind.allCases {
            sub.addItem(check(kind.label, Settings.engine == kind,
                              #selector(selectEngine(_:)), represented: kind.rawValue))
        }

        sub.addItem(.separator())
        for model in ParakeetModel.allCases {
            let installed = ParakeetEngine.shared.isInstalled(model)
            let title = installed ? model.label : "\(model.label) — not downloaded"
            sub.addItem(check(title, Settings.parakeetModel == model,
                              #selector(selectParakeetModel(_:)), represented: model.rawValue))
        }

        sub.addItem(.separator())
        let current = Settings.parakeetModel
        if ParakeetEngine.shared.isInstalled(current) {
            sub.addItem(item("Unload Parakeet from memory", #selector(unloadParakeet), nil))
        } else {
            sub.addItem(item("Download \(current.shortLabel) now", #selector(downloadParakeet), nil))
        }
        sub.addItem(item("Reveal Parakeet Models Folder", #selector(openParakeetModels), nil))

        parent.submenu = sub
        return parent
    }

    private func languageMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for lang in languages {
            sub.addItem(check(lang.label, Settings.language == lang.code, #selector(selectLanguage(_:)), represented: lang.code))
        }
        parent.submenu = sub
        return parent
    }

    private func permissionsMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let micStatus = Recorder.isAuthorized ? "Microphone: granted ✓" : "Microphone: not granted"
        let mic = item(micStatus, #selector(requestMic), nil)
        sub.addItem(mic)
        if !Recorder.isAuthorized {
            sub.addItem(item("Open Microphone Settings", #selector(openMicSettings), nil))
        }

        let ax = item(AXIsProcessTrusted() ? "Accessibility (paste): granted ✓" : "Accessibility (paste): grant to enable auto-paste",
                      #selector(grantAccessibility), nil)
        sub.addItem(ax)
        parent.submenu = sub
        return parent
    }

    private func loginItem() -> NSMenuItem {
        let enabled = SMAppService.mainApp.status == .enabled
        return check("Launch at Login", enabled, #selector(toggleLogin))
    }

    private func item(_ title: String, _ action: Selector?, _ key: String?, represented: Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key ?? "")
        i.target = action == nil ? nil : self
        i.representedObject = represented
        i.isEnabled = action != nil
        if let key, !key.isEmpty { i.keyEquivalentModifierMask = [.command, .shift] }
        return i
    }

    private func check(_ title: String, _ on: Bool, _ action: Selector, represented: Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        i.representedObject = represented
        return i
    }

    @objc private func copyLast() {
        guard let lastTranscript else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lastTranscript, forType: .string)
    }

    @objc private func openNotes() { NSWorkspace.shared.open(AppPaths.transcripts) }
    @objc private func openAudio() { NSWorkspace.shared.open(AppPaths.audio) }
    @objc private func openModels() { NSWorkspace.shared.open(AppPaths.models) }

    @objc private func toggleAutoPaste() {
        Settings.autoPaste.toggle()
        if Settings.autoPaste, !AXIsProcessTrusted() { promptAccessibility() }
    }

    @objc private func toggleKeepAudio() { Settings.keepAudio.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            vlog("login item toggle failed: \(error.localizedDescription)")
            Shell.notify("VoiceNote", "Launch at Login failed: \(error.localizedDescription)")
        }
    }

    @objc private func requestMic() {
        Recorder.requestPermission { granted in
            if !granted {
                Shell.notify("VoiceNote", "Grant microphone access in System Settings ▸ Privacy & Security ▸ Microphone.")
            }
        }
    }

    @objc private func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func grantAccessibility() { promptAccessibility() }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.model = name
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = AsrEngineKind(rawValue: raw) else { return }
        Settings.engine = kind
        vlog("engine set to \(kind.rawValue)")
        if kind == .parakeet {
            let model = Settings.parakeetModel
            if !ParakeetEngine.shared.isInstalled(model) {
                Shell.notify("VoiceNote", "Parakeet models download on first use — the next recording will pause while they fetch.")
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    try ParakeetEngine.shared.preload(model: model) { message in
                        DispatchQueue.main.async { self?.hudProgress(message) }
                    }
                    DispatchQueue.main.async { self?.hud.showDone("parakeet ready ✓") }
                } catch {
                    vlog("preload failed: \(error.localizedDescription)")
                    DispatchQueue.main.async { self?.hud.showError("Parakeet unavailable") }
                }
            }
        }
    }

    @objc private func selectParakeetModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let model = ParakeetModel(rawValue: raw) else { return }
        Settings.parakeetModel = model
        ParakeetEngine.shared.unload()
        vlog("parakeet model set to \(model.shortLabel)")
        guard Settings.engine == .parakeet else { return }
        hudProgress("Loading \(model.shortLabel)…")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try ParakeetEngine.shared.preload(model: model) { message in
                    DispatchQueue.main.async { self?.hudProgress(message) }
                }
                DispatchQueue.main.async { self?.hud.showDone("\(model.shortLabel) ready ✓") }
            } catch {
                DispatchQueue.main.async { self?.hud.showError("Could not load \(model.shortLabel)") }
            }
        }
    }

    @objc private func downloadParakeet() {
        let model = Settings.parakeetModel
        hudProgress("Downloading \(model.shortLabel)…")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try ParakeetEngine.shared.download(model: model) { message in
                    DispatchQueue.main.async { self?.hudProgress(message) }
                }
                DispatchQueue.main.async { self?.hud.showDone("\(model.shortLabel) ready ✓") }
            } catch {
                DispatchQueue.main.async { self?.hud.showError("Download failed") }
                Shell.notify("VoiceNote", "Parakeet download failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func unloadParakeet() {
        ParakeetEngine.shared.unload()
        Shell.notify("VoiceNote", "Parakeet models unloaded from memory.")
    }

    @objc private func openParakeetModels() {
        NSWorkspace.shared.open(ParakeetEngine.shared.modelsRoot)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Settings.language = code
    }

    @objc private func downloadModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        downloader.download(name)
    }
}
