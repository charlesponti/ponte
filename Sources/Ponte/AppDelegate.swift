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

    /// Watches the input while recording, so a take producing nothing says so in time (see `InputWatch`).
    private var inputWatch: InputWatch?
    private var watchTimer: Timer?

    /// Esc and Return, held only while a dictation is in flight — see `DictationKey`.
    private var dictationKeys: [GlobalHotKey] = []

    /// Set when Esc lands while the transcript is being computed: the result is dropped rather than
    /// pasted into whatever the person has since turned to.
    private var discardResult = false

    private var state: AppState = .idle {
        didSet {
            // The keys are grabbed for exactly as long as there is a dictation to cancel.
            if state == .idle { releaseDictationKeys() } else { grabDictationKeys() }
        }
    }

    /// A single physical press can deliver two hotkey events (key down/up, or key
    /// repeat). Swallow the duplicate so one press never spawns two recorders.
    private var lastHotKeyAt = Date.distantPast
    private let hotKeyDebounce: TimeInterval = 0.25

    private var lastTranscript: String?
    private var progressItem: NSMenuItem?

    /// Whether the engine's models are on disk and loaded — see `Readiness`.
    private var readiness: Readiness = .ready

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


        let code = Settings.hotKey(SettingKey.hotKeyCode, default: HotKeySpec.defaultKeyCode)
        let mods = Settings.hotKey(SettingKey.hotKeyMods, default: HotKeySpec.defaultModifiers)
        hotKey = GlobalHotKey(keyCode: code, modifiers: mods) { [weak self] in self?.toggle() }
        if hotKey == nil {
            Shell.notify("Ponte", "Hotkey \(HotKeySpec.describe(keyCode: code, modifiers: mods)) is taken — use the menu icon.")
        }

        downloader.onProgress = { [weak self] text in
            self?.progressItem?.title = text
            self?.hudProgress(text)
        }
        downloader.onFinish = { result in
            switch result {
            case .success(let url):
                Settings.model = url.lastPathComponent
                Shell.notify("Ponte", "Model ready: \(url.lastPathComponent)")
            case .failure(let error):
                Shell.notify("Ponte", "Download failed: \(error.localizedDescription)")
            }
        }

        if Whisper.binary() == nil {
            Shell.notify("Ponte", "whisper-cli not found — run: brew install whisper-cpp")
        }

        // Ask for the microphone once at first launch instead of surprising you
        // mid-sentence on the first hotkey press.
        if !UserDefaults.standard.bool(forKey: "didPromptMic") {
            UserDefaults.standard.set(true, forKey: "didPromptMic")
            Recorder.requestPermission { granted in
                vlog("first-run microphone prompt answered granted=\(granted)")
            }
        }

        // Warm the engine before anything is asked of it: the first run has to fetch ~613 MB, and the
        // one-time Neural Engine specialisation costs the first transcription ~7-10 s on top.
        prepareEngine()

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

        guard readiness.allowsDictation else {
            declineWhileGettingReady()
            return
        }

        switch state {
        case .idle: startRecording()
        case .starting: vlog("hotkey ignored — recording is already starting")
        case .recording: stopAndTranscribe()
        case .working: NSSound.beep()
        }
    }

    // MARK: - Watching the input

    private func startWatchingInput() {
        inputWatch = InputWatch()
        watchTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.sampleInput() }
        // .common, not the default mode: the timer has to keep ticking while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private func stopWatchingInput() {
        watchTimer?.invalidate()
        watchTimer = nil
        inputWatch = nil
    }

    /// One reading of the meter, four times a second. Only transitions are logged and drawn, so a
    /// quiet take says its piece once rather than every quarter second.
    private func sampleInput() {
        guard case .recording = state, var watch = inputWatch else { return }
        let before = watch.verdict
        let after = watch.observe(peakDB: recorder.newestPeakDB, at: recorder.elapsed)
        inputWatch = watch
        guard after != before else { return }
        hud.setHint(after.label)
        switch after {
        case .noSignal:
            vlog(String(format: "input watch: no signal — loudest peak %.0f dBFS after %.1fs on %@",
                        watch.loudestDB, recorder.elapsed, recorder.deviceName))
        case .listening:
            vlog(String(format: "input watch: the input is back (loudest peak %.0f dBFS)", watch.loudestDB))
        }
    }

    // MARK: - Getting ready

    /// Make sure the selected engine can transcribe, saying so while it cannot.
    ///
    /// Called at launch and whenever the engine or model changes. An installed model is warmed silently —
    /// it costs a fraction of a second and pays for the Neural Engine compile. A missing one is fetched
    /// with its progress on screen, and dictation is declined until it is done.
    private func prepareEngine() {
        let engine = Settings.engine
        guard engine == .parakeet else {
            let installed = Whisper.installedModels().contains(Settings.model)
            setReadiness(installed ? .ready
                                   : .failed("No speech model installed — pick one under Model"))
            return
        }
        let model = Settings.parakeetModel
        if ParakeetEngine.shared.isInstalled(model) {
            setReadiness(.ready)
            // preload logs its own timing
            DispatchQueue.global(qos: .utility).async {
                do {
                    try ParakeetEngine.shared.preload(model: model)
                } catch {
                    vlog("preload failed: \(error.localizedDescription)")
                }
            }
            return
        }

        let note = "Getting the speech model"
        setReadiness(.preparing(percent: nil, note: note))
        vlog("parakeet models missing for \(model.shortLabel) — fetching before any dictation")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report: (String) -> Void = { message in
                let percent = Readiness.percent(in: message)
                DispatchQueue.main.async {
                    self?.setReadiness(.preparing(percent: percent, note: note))
                }
            }
            do {
                try ParakeetEngine.shared.download(model: model, progress: report)
                try ParakeetEngine.shared.preload(model: model, progress: report)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setReadiness(.ready)
                    Shell.notify("Ponte", "Ready — \(self.hotKeyDescription) starts a dictation.")
                }
            } catch {
                vlog("model preparation failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.setReadiness(.failed("Could not fetch the speech model"))
                    Shell.notify("Ponte", "Ponte could not fetch its speech model: \(error.localizedDescription)")
                }
            }
        }
    }

    private func setReadiness(_ next: Readiness) {
        guard next != readiness else { return }
        let wasReady = readiness.allowsDictation
        readiness = next
        updateIcon()
        switch next {
        case .ready:
            if !wasReady { hud.showDone("Ready ✓") }
            vlog("readiness: ready")
        case .preparing(let percent, let note):
            if let percent { hud.showDownload(percent: percent) } else { hud.showWorking() }
            vlog("readiness: preparing\(percent.map { " \($0)%" } ?? "") (\(note))")
        case .failed(let message):
            hud.showError(message)
            vlog("readiness: failed — \(message)")
        }
    }

    /// Someone pressed the hotkey before the engine could honour it. Say so in the pill rather than
    /// swallowing the press: the take would otherwise be recorded and then wait minutes for a download.
    private func declineWhileGettingReady() {
        hud.setHint(nil)
        switch readiness {
        case .preparing(let percent, _):
            // Amber and calm: this is a download in progress, not a fault.
            hud.showGettingReady(percent: percent)
            vlog("dictation declined — still getting ready\(percent.map { " (\($0)%)" } ?? "")")
        case .failed(let message):
            hud.showError(message)
            vlog("dictation declined — \(message)")
        case .ready:
            break
        }
    }

    private var hotKeyDescription: String {
        HotKeySpec.describe(keyCode: hotKey?.keyCode ?? HotKeySpec.defaultKeyCode,
                            modifiers: hotKey?.modifiers ?? HotKeySpec.defaultModifiers)
    }

    // MARK: - Keys during a dictation

    private func grabDictationKeys() {
        guard dictationKeys.isEmpty else { return }
        dictationKeys = DictationKey.allCases.compactMap { key in
            GlobalHotKey(keyCode: key.keyCode, modifiers: 0) { [weak self] in
                switch key.meaning {
                case .cancel: self?.cancel()
                case .commit: self?.commit()
                }
            }
        }
        vlog("dictation keys grabbed (\(DictationKey.hints)) — \(dictationKeys.count)/\(DictationKey.allCases.count) registered")
    }

    private func releaseDictationKeys() {
        guard !dictationKeys.isEmpty else { return }
        dictationKeys.removeAll()
        vlog("dictation keys released")
    }

    /// Esc, while a dictation is in flight: throw the take away.
    ///
    /// Nothing is transcribed and no note is written, and the audio goes with it — cancelled means no
    /// trace, whatever the keep-audio setting says, because that setting is about dictations and this
    /// one is not going to become one.
    private func cancel() {
        switch state {
        case .starting, .recording:
            stopWatchingInput()
            let elapsed = recorder.elapsed
            let url = recorder.stop()
            if let url { try? FileManager.default.removeItem(at: url) }
            vlog(String(format: "cancelled after %.2fs — audio discarded, nothing transcribed", elapsed))
            state = .idle
            updateIcon()
            hud.showCancelled()
        case .working:
            discardResult = true
            vlog("cancelled while transcribing — the result will be dropped")
            hud.showCancelled()
        case .idle:
            break
        }
    }

    /// Return, while recording: finish now, exactly as pressing the hotkey again does.
    private func commit() {
        switch state {
        case .starting: vlog("Return ignored — the microphone is still opening")
        case .recording: stopAndTranscribe()
        case .working, .idle: break
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
                Shell.notify("Ponte", "Microphone access denied. Grant it in System Settings ▸ Privacy & Security ▸ Microphone.")
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
            if let columns = self.recorder.columns {
                self.hud.use(columns: columns, clock: self.recorder.clock,
                             columnsPerSecond: HudSpec.columnsPerSecond)
            }
            self.hud.beginRecording()
            self.startWatchingInput()
        }
    }

    private func stopAndTranscribe() {
        stopWatchingInput()
        let elapsed = recorder.elapsed
        guard let url = recorder.stop() else {
            state = .idle
            updateIcon()
            return
        }
        // Nothing captured: the wrong input device, or one that is asleep (AirPods in their case),
        // leaves a file with no audio in it. Transcribing that reports "invalid audio", which tells
        // the person nothing about what to do — so say what actually happened.
        guard elapsed >= 0.3 else {
            vlog(String(format: "nothing recorded (%.2fs) — not transcribing", elapsed))
            cleanUp(audio: url)
            hud.showError("Nothing was recorded — check the microphone")
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
                    if self.discardResult {
                        self.discardResult = false
                        vlog("transcript dropped — cancelled while transcribing")
                        self.state = .idle
                        self.updateIcon()
                        self.cleanUp(audio: url)
                        return
                    }
                    self.finish(text: result.text, took: result.seconds, audio: url,
                                elapsed: elapsed, engine: result.engine)
                }
            } catch {
                vlog("transcribe failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    if self.discardResult {
                        self.discardResult = false
                        self.state = .idle
                        self.updateIcon()
                        self.cleanUp(audio: url)
                        return
                    }
                    self.state = .idle
                    self.updateIcon()
                    self.hud.showError("Transcription failed")
                    Shell.notify("Ponte", error.localizedDescription)
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
            hud.showDone("Copied — press ⌘V")
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
        Shell.notify("Ponte",
                     "Auto-paste needs Accessibility. Ponte icon ▸ Permissions ▸ Repair permissions (clear a stale grant) fixes the usual cause — a grant left over from an earlier build. Until then the text goes to the clipboard.")
    }

    /// Progress arrives as prose ("Downloading Parakeet models… 43% (12/20 files)").
    /// The HUD has room for the number, so show that; otherwise just the orb.
    private func hudProgress(_ message: String) {
        if let percent = Readiness.percent(in: message) {
            hud.showDownload(percent: percent)
        } else {
            hud.showWorking()
        }
    }

    private func updateIcon() {
        // At rest the menu bar wears the app's own mark; the momentary states keep their glyphs,
        // because "recording" is worth more than branding while it is happening (the orb is on
        // screen in the HUD at that point anyway).
        statusItem?.button?.image = StatusIcon.image(for: state)
        statusItem?.button?.contentTintColor = StatusIcon.tint(for: state)
        let shortcut = hotKeyDescription
        statusItem?.button?.toolTip = readiness.allowsDictation
            ? "Ponte — \(shortcut) · \(DictationKey.hints)"
            : "Ponte — \(readiness.menuTitle) · \("dictation is declined until this finishes")"

        // The item moves when the bar re-lays out — macOS adds its own microphone pill while we
        // record — so where it is has to be re-read per state, not remembered from launch.
        if let f = statusItem?.button?.window?.frame {
            vlog("icon \(state) at x=\(Int(f.origin.x)) y=\(Int(f.origin.y)) w=\(Int(f.width)) h=\(Int(f.height))")
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shortcut = HotKeySpec.describe(keyCode: hotKey?.keyCode ?? HotKeySpec.defaultKeyCode,
                                           modifiers: hotKey?.modifiers ?? HotKeySpec.defaultModifiers)

        switch state {
        case .idle:
            if readiness.allowsDictation {
                menu.addItem(item("Start Recording", #selector(toggle), shortcut))
            } else {
                let waiting = item(readiness.menuTitle, #selector(explainReadiness), nil)
                waiting.isEnabled = true
                menu.addItem(waiting)
            }
        case .starting:
            menu.addItem(hint("Starting…"))
        case .recording:
            menu.addItem(item("Stop & Transcribe", #selector(toggle), shortcut))
            menu.addItem(hint(DictationKey.hints))
        case .working:
            menu.addItem(hint("Transcribing…"))
            menu.addItem(hint(DictationKey.hints))
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

        let quit = NSMenuItem(title: "Quit Ponte", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

        let trusted = AXIsProcessTrusted()
        sub.addItem(item(trusted ? "Accessibility (paste): granted ✓"
                                 : "Accessibility (paste): not granted — click to grant",
                         #selector(grantAccessibility), nil))
        if !trusted {
            sub.addItem(item("Repair permissions (clear a stale grant)", #selector(repairAccessibility), nil))
        }
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

    /// A disabled line, for something worth reading but not clicking.
    private func hint(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
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
            Shell.notify("Ponte", "Launch at Login failed: \(error.localizedDescription)")
        }
    }

    @objc private func requestMic() {
        Recorder.requestPermission { granted in
            if !granted {
                Shell.notify("Ponte", "Grant microphone access in System Settings ▸ Privacy & Security ▸ Microphone.")
            }
        }
    }

    @objc private func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func grantAccessibility() { promptAccessibility() }

    /// Clicking the state line just says it again in the pill — the detail lives in the log and in this
    /// line's own text.
    @objc private func explainReadiness() { declineWhileGettingReady() }

    /// A grant made against an older signature stays switched on in System Settings while applying to
    /// nothing at all, which is how auto-paste can stop working with nothing looking wrong. Clear the
    /// entry and ask again, so the next grant binds to the build that is actually running.
    @objc private func repairAccessibility() {
        let id = Bundle.main.bundleIdentifier ?? "com.ponti.ponte"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", id]
        do {
            try task.run()
            task.waitUntilExit()
            vlog("reset the accessibility entry for \(id) status=\(task.terminationStatus)")
        } catch {
            vlog("could not reset the accessibility entry: \(error.localizedDescription)")
            Shell.notify("Ponte", "Could not clear the old permission. Open System Settings ▸ Privacy & Security ▸ Accessibility and remove Ponte with the − button.")
            return
        }
        hasPromptedAccessibility = false
        promptAccessibility()
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.model = name
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = AsrEngineKind(rawValue: raw) else { return }
        Settings.engine = kind
        vlog("engine set to \(kind.rawValue)")
        prepareEngine()
        if kind == .parakeet {
            let model = Settings.parakeetModel
            if !ParakeetEngine.shared.isInstalled(model) {
                Shell.notify("Ponte", "Parakeet models download on first use — the next recording will pause while they fetch.")
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
        prepareEngine()
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
                Shell.notify("Ponte", "Parakeet download failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func unloadParakeet() {
        ParakeetEngine.shared.unload()
        Shell.notify("Ponte", "Parakeet models unloaded from memory.")
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
