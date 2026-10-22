import AppKit
import AVFoundation
import Foundation

// VoiceNote — push-to-talk dictation for macOS, fully on-device.
//
//   VoiceNote                 → menu bar app (global hotkey to record/transcribe)
//   VoiceNote --help          → usage
//   VoiceNote --devices       → list audio input devices
//   VoiceNote --record 5      → record 5 seconds to a WAV (debugging)
//   VoiceNote --transcribe f  → transcribe an existing WAV
//   VoiceNote --selftest 5    → record 5s from the mic and transcribe it (end-to-end check)

let argv = CommandLine.arguments

func usage() {
    print("""
    VoiceNote — local push-to-talk dictation

    USAGE
      VoiceNote                      run the menu bar app
      VoiceNote --record <seconds> [--out <file.wav>]
      VoiceNote --transcribe <file.wav> [--engine whisper|parakeet]
                                        [--parakeet-model ultra|v3|v2|redux]
                                        [--model <whisper model>] [--language <code>]
      VoiceNote --bench <file.wav>    run every installed engine on one file and compare
      VoiceNote --download [ultra|v3|v2|redux|all]
      VoiceNote --selftest <seconds> [--engine …]
      VoiceNote --devices
      VoiceNote --hud-render <out.png> <idle|recording|working|done|error> [t] [text]
      VoiceNote --hud-strip <out.png>       render the lifecycle as a contact sheet
      VoiceNote --hud-voice <out.png>       render the orb answering a voice
      VoiceNote --help

    whisper models live in \(AppPaths.models.path)
    Parakeet (CoreML/ANE) models live in \(ParakeetEngine.shared.installPath(.ultra).path)
    Notes are written to \(AppPaths.transcripts.path)
    """)
}

func listDevices() {
    let session = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external],
        mediaType: .audio,
        position: .unspecified)
    print("audio input devices:")
    for (i, d) in session.devices.enumerated() {
        let isDefault = d.uniqueID == AVCaptureDevice.default(for: .audio)?.uniqueID
        print("  [\(i)] \(d.localizedName)\(isDefault ? "   (system default)" : "")")
    }
    print("whisper binary: \(Whisper.binary()?.path ?? "NOT FOUND")")
    print("models: \(Whisper.installedModels().isEmpty ? "none" : Whisper.installedModels().joined(separator: ", "))")
}

/// Record synchronously, spinning a run loop so AVAudioRecorder can do its work.
func recordSync(seconds: Double, out: URL?) throws -> URL {
    let rec = Recorder()
    let url = try rec.start()
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    rec.stop()
    if let out {
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: url, to: out)
        return out
    }
    return url
}

func requestMicBlocking() -> Bool {
    var granted = false
    var done = false
    Recorder.requestPermission { ok in
        granted = ok
        done = true
    }
    let deadline = Date().addingTimeInterval(60)
    while !done && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return granted
}

func value(of flag: String) -> String? {
    guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

func audioDuration(_ url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return 0 }
    return Double(file.length) / file.processingFormat.sampleRate
}

func engineFlags() -> (AsrEngineKind, ParakeetModel, String) {
    let kind = AsrEngineKind(rawValue: value(of: "--engine") ?? "") ?? Settings.engine
    let model = ParakeetModel(rawValue: value(of: "--parakeet-model") ?? "") ?? Settings.parakeetModel
    let language = value(of: "--language") ?? Settings.language
    return (kind, model, language)
}

/// Run one engine a few times over the same file and report first/warm timings plus the text.
func bench(_ label: String, runs: Int, audioSeconds: Double, _ work: () throws -> Transcriber.Result) {
    var times: [Double] = []
    var text = ""
    for _ in 0..<runs {
        let started = Date()
        do {
            let result = try work()
            times.append(Date().timeIntervalSince(started))
            text = result.text
        } catch {
            print("  \(label): FAILED — \(error.localizedDescription)")
            return
        }
    }
    let warm = times.dropFirst().min() ?? times[0]
    let speed = warm > 0 ? audioSeconds / warm : 0
    print(String(format: "  %-30@ first %5.2fs   warm %5.2fs   %6.1fx realtime",
                 label as NSString, times[0], warm, speed))
    print("     \"\(text.prefix(220))\"")
}

// MARK: - CLI dispatch

func defaultHudText(for state: HudState) -> String {
    switch state {
    case .idle, .working: return "…"
    case .recording: return "0:07"
    case .done: return "Pasted ✓ 0.2s"
    case .error: return "Heard nothing"
    }
}

func hudColour(for state: HudState) -> NSColor {
    switch state {
    case .done: return HudSpec.green
    case .error: return HudSpec.red
    default: return NSColor.white.withAlphaComponent(0.55)
    }
}

@discardableResult
func writePNG(_ image: NSImage, to path: String) -> Int32 {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("error: could not encode PNG")
        return 1
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        return 0
    } catch {
        print("error: \(error.localizedDescription)")
        return 1
    }
}

/// The lifecycle as a contact sheet, drawn by the app's own renderer.
func writeHUDSheet(to path: String) -> Int32 {
    struct Frame { let t: Double; let spin: Float; var note: String = "" }
    struct Row { let title: String; let state: HudState; let text: String; let colour: NSColor; let frames: [Frame] }

    let rows: [Row] = [
        Row(title: "Done — the box collapses to text + 16 px", state: .done,
            text: defaultHudText(for: .done), colour: HudSpec.green,
            frames: [Frame(t: 0.00, spin: 1.10), Frame(t: 0.15, spin: 1.30), Frame(t: 0.30, spin: 1.50),
                     Frame(t: 0.45, spin: 1.70), Frame(t: 0.60, spin: 1.85), Frame(t: 0.70, spin: 1.95)]),
        Row(title: "Error — three throbs, then the box follows", state: .error,
            text: defaultHudText(for: .error), colour: HudSpec.red,
            // A trough is included next to a peak: the throb is a 15 % scale change, and
            // without both you cannot see it in a still.
            frames: [Frame(t: 0.00, spin: 1.10, note: "mint"),
                     Frame(t: 0.18, spin: 1.25, note: "red"),
                     Frame(t: 0.43, spin: 1.30, note: "trough"),
                     Frame(t: 0.64, spin: 1.35, note: "throb 1 peak"),
                     Frame(t: 1.06, spin: 1.45, note: "throb 2 peak"),
                     Frame(t: 1.48, spin: 1.55, note: "throb 3 peak"),
                     Frame(t: 1.92, spin: 1.70, note: "exiting"),
                     Frame(t: 2.20, spin: 1.80, note: "text only")]),
    ]

    return writeSheet(rows.map { row in
        SheetRow(title: row.title, cells: row.frames.map { frame in
            let geometry = HudLifecycle.geometry(row.state, frame.t,
                                                 target: HudLifecycle.pillSize(for: row.text))
            var caption = String(format: "%.2fs  box %.0f×%.0f", frame.t,
                                 geometry.box.width, geometry.box.height)
            if !frame.note.isEmpty { caption += "  " + frame.note }
            return SheetCell(caption: caption,
                             image: HUD.render(state: row.state, t: frame.t, text: row.text,
                                               colour: row.colour, spin: frame.spin))
        })
    }, to: path)
}

/// The orb answering a voice: a row of steady levels, and a row of a word being spoken.
func writeVoiceSheet(to path: String) -> Int32 {
    let dim = NSColor.white.withAlphaComponent(0.55)

    func steady(_ level: Float) -> VoiceProfile { { _ in (level, level) } }

    /// A syllable every 250 ms, so the rings along the sphere are visible in a still.
    let syllables: VoiceProfile = { age in
        let secondsAgo = Double(age) * HudSpec.voiceHistory
        let envelope = abs(sin(secondsAgo * .pi / 0.25))
        let level = Float(max(0, envelope - 0.2) / 0.8)
        return (level, min(1, level * 1.6))
    }

    let levels = SheetRow(
        title: "The orb answers the level (silence → full voice)",
        cells: [0.0, 0.25, 0.5, 0.75, 1.0].map { level in
            SheetCell(caption: String(format: "level %.2f  →  dots ×%.2f", level,
                                      1 + Double(OrbProjection.gain) * level),
                      image: HUD.render(state: .recording, t: 0, text: "0:07", colour: dim,
                                        spin: 1.1, voice: steady(Float(level))))
        })
    let word = SheetRow(
        title: "A word being spoken: 0.8 s of voice, equator (now) to poles (0.8 s ago)",
        cells: [0.0, 0.2, 0.4, 0.6, 0.8, 1.0].map { moment in
            // The picture advances through the word, so each frame catches the sound at a different age.
            let profile: VoiceProfile = { age in syllables(Float(max(0, min(1, Double(age) + moment)))) }
            return SheetCell(caption: String(format: "%.2f s in", moment),
                             image: HUD.render(state: .recording, t: 0, text: "0:07", colour: dim,
                                               spin: 1.1 + Float(moment), voice: profile))
        })
    return writeSheet([levels, word], to: path)
}

struct SheetCell {
    let caption: String
    let image: NSImage
}

struct SheetRow {
    let title: String
    let cells: [SheetCell]
}

/// Draws a contact sheet of pre-rendered frames, two pixels per point.
func writeSheet(_ rows: [SheetRow], to path: String) -> Int32 {
    let cellW: CGFloat = 152, cellH: CGFloat = 124, pad: CGFloat = 26
    let titleH: CGFloat = 30, captionH: CGFloat = 30, rowGap: CGFloat = 14
    let maxFrames = rows.map(\.cells.count).max() ?? 1
    let width = pad * 2 + CGFloat(maxFrames) * cellW
    let height = pad * 2 + CGFloat(rows.count) * (titleH + cellH + captionH + rowGap)
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        print("error: could not create the sheet")
        return 1
    }
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSColor(srgbRed: 0.043, green: 0.043, blue: 0.051, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        .foregroundColor: NSColor.white]
    let captionAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor.white.withAlphaComponent(0.55)]

    var y = height - pad
    for row in rows {
        y -= titleH
        row.title.draw(at: CGPoint(x: pad, y: y + 8), withAttributes: titleAttrs)
        y -= cellH
        for (index, cell) in row.cells.enumerated() {
            let x = pad + CGFloat(index) * cellW
            let box = cell.image.size
            cell.image.draw(in: CGRect(x: x + (cellW - box.width) / 2,
                                       y: y + (cellH - box.height) / 2,
                                       width: box.width, height: box.height))
            cell.caption.draw(at: CGPoint(x: x + 8, y: y - 16), withAttributes: captionAttrs)
        }
        y -= captionH + rowGap
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("error: could not encode PNG")
        return 1
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        return 0
    } catch {
        print("error: \(error.localizedDescription)")
        return 1
    }
}

func runCLI() -> Int32? {
    guard argv.count > 1 else { return nil }

    switch argv[1] {
    case "--help", "-h", "help":
        usage()
        return 0

    case "--devices":
        listDevices()
        return 0

    case "--transcribe":
        guard argv.count > 2 else { print("usage: VoiceNote --transcribe <file.wav>"); return 2 }
        let file = URL(fileURLWithPath: argv[2])
        guard FileManager.default.fileExists(atPath: file.path) else {
            print("no such file: \(file.path)"); return 2
        }
        let language = value(of: "--language") ?? Settings.language
        let (kind, parakeetModel, lang) = engineFlags()
        do {
            let result = try AsrEngine.transcribe(wav: file, engine: kind, parakeetModel: parakeetModel,
                                                  language: lang) { message in
                FileHandle.standardError.write("  \(message)\n".data(using: .utf8)!)
            }
            print(result.text)
            FileHandle.standardError.write("(\(String(format: "%.2f", result.seconds))s, engine=\(result.engine))\n".data(using: .utf8)!)
            _ = language
            return result.text.isEmpty ? 1 : 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }

    case "--download":
        let requested = argv.count > 2 && argv[2] != "all" ? [argv[2]] : ParakeetModel.allCases.map { $0.rawValue }
        for name in requested {
            guard let model = ParakeetModel(rawValue: name) else {
                print("unknown parakeet model: \(name) (try ultra, v3, v2, redux)"); return 2
            }
            if ParakeetEngine.shared.isInstalled(model) {
                print("\(model.shortLabel): already installed at \(ParakeetEngine.shared.installPath(model).path)")
                continue
            }
            print("downloading \(model.shortLabel)…")
            do {
                try ParakeetEngine.shared.download(model: model) { message in print("  \(message)") }
                print("\(model.shortLabel): ready at \(ParakeetEngine.shared.installPath(model).path)")
            } catch {
                print("\(model.shortLabel): failed — \(error.localizedDescription)")
                return 1
            }
        }
        return 0

    case "--bench":
        guard argv.count > 2 else { print("usage: VoiceNote --bench <file.wav>"); return 2 }
        let file = URL(fileURLWithPath: argv[2])
        guard FileManager.default.fileExists(atPath: file.path) else { print("no such file: \(file.path)"); return 2 }
        let seconds = audioDuration(file)
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        let (_, benchModel, benchLang) = engineFlags()
        print("file: \(file.lastPathComponent)  \(String(format: "%.2f", seconds))s  \(bytes / 1024) KB  language=\(benchLang)")
        print("whisper:")
        bench("whisper.cpp \(Settings.model)", runs: 3, audioSeconds: seconds) {
            try Transcriber.transcribe(wav: file, modelName: Settings.model, language: benchLang)
        }
        print("parakeet (Neural Engine):")
        for model in ParakeetModel.allCases {
            let installed = ParakeetEngine.shared.isInstalled(model)
            if installed || model == benchModel {
                bench("parakeet \(model.shortLabel)", runs: 3, audioSeconds: seconds) {
                    try ParakeetEngine.shared.transcribe(wav: file, model: model,
                                                         language: ParakeetEngine.languageHint(benchLang),
                                                         progress: nil)
                }
            } else {
                print("  parakeet \(model.shortLabel): not downloaded (VoiceNote --download \(model.rawValue))")
            }
        }
        return 0

    case "--hud-render":
        guard argv.count > 3, let state = HudState(rawValue: argv[3]) else {
            print("usage: VoiceNote --hud-render <out.png> <idle|recording|working|done|error> [t] [text]")
            return 2
        }
        let t = argv.count > 4 ? (Double(argv[4]) ?? 0) : 0
        let text = argv.count > 5 ? argv[5]
            : (state == .recording ? HudLifecycle.clock(t) : defaultHudText(for: state))
        return writePNG(HUD.render(state: state, t: t, text: text, colour: hudColour(for: state)),
                        to: argv[2])

    case "--orb-level":
        guard argv.count > 3, let level = Float(argv[3]) else {
            print("usage: VoiceNote --orb-level <out.png> <level 0...1>")
            return 2
        }
        return writePNG(HUD.render(state: .recording, t: 0,
                                   text: HudLifecycle.clock(7), colour: hudColour(for: .recording),
                                   spin: 1.1, voice: { _ in (level, level) }), to: argv[2])

    case "--hud-voice":
        guard argv.count > 2 else { print("usage: VoiceNote --hud-voice <out.png>"); return 2 }
        return writeVoiceSheet(to: argv[2])

    case "--hud-strip":
        guard argv.count > 2 else { print("usage: VoiceNote --hud-strip <out.png>"); return 2 }
        return writeHUDSheet(to: argv[2])

    case "--record":
        let seconds = Double(value(of: "--record") ?? "") ?? 5
        let out = value(of: "--out").map { URL(fileURLWithPath: $0) }
        guard requestMicBlocking() else { print("error: microphone access denied"); return 1 }
        do {
            let url = try recordSync(seconds: seconds, out: out)
            print(url.path)
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }

    case "--selftest":
        let seconds = Double(argv.count > 2 ? argv[2] : "") ?? 5
        guard requestMicBlocking() else { print("error: microphone access denied"); return 1 }
        do {
            print("recording \(seconds)s…")
            let url = try recordSync(seconds: seconds, out: nil)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            print("captured \(url.lastPathComponent) (\(size) bytes)")
            let result = try AsrEngine.transcribe(wav: url) { message in print("  \(message)") }
            print("transcript (\(String(format: "%.2f", result.seconds))s): \(result.text)")
            try? FileManager.default.removeItem(at: url)
            return result.text.isEmpty ? 1 : 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }

    default:
        return nil
    }
}

if let code = runCLI() {
    exit(code)
}

// MARK: - GUI

Settings.registerDefaults()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
