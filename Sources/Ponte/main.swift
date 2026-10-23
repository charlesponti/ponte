import AppKit
import SwiftUI
import WaveformCore
import WaveformUI
import AVFoundation
import Foundation

// Ponte — push-to-talk dictation for macOS, fully on-device.
//
//   Ponte                 → menu bar app (global hotkey to record/transcribe)
//   Ponte --help          → usage
//   Ponte --devices       → list audio input devices
//   Ponte --record 5      → record 5 seconds to a WAV (debugging)
//   Ponte --transcribe f  → transcribe an existing WAV
//   Ponte --selftest 5    → record 5s from the mic and transcribe it (end-to-end check)

let argv = CommandLine.arguments

func usage() {
    print("""
    Ponte — local push-to-talk dictation

    USAGE
      Ponte                      run the menu bar app
      Ponte --record <seconds> [--out <file.wav>]
      Ponte --transcribe <file.wav> [--engine whisper|parakeet]
                                        [--parakeet-model ultra|v3|v2|redux]
                                        [--model <whisper model>] [--language <code>]
      Ponte --bench <file.wav>    run every installed engine on one file and compare
      Ponte --download [ultra|v3|v2|redux|all]
      Ponte --selftest <seconds> [--engine …]
      Ponte --devices
      Ponte --hud-render <out.png> <idle|recording|working|done|error|cancelled> [t] [text] [amber|red|green|grey|dim]
      Ponte --hud-strip <out.png>       render the lifecycle as a contact sheet
      Ponte --hud-voice <out.png>       render the orb answering a voice
      Ponte --icon <out.png> <mark> [px]  render the app icon (orb|halftone|ripple|core)
      Ponte --status-icon <out.png> [pt]  render the menu bar mark
      Ponte --icon-sheet <out.png>      every mark at every size
      Ponte --help

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
    case .done: return "Pasted ✓"
    case .error: return "Heard nothing"
    case .cancelled: return "Cancelled"
    }
}

/// Colours a rendered state can be asked for by name, matching what the app passes at the call site.
func hudNamedColour(_ name: String) -> NSColor? {
    switch name {
    case "amber": return HudSpec.amber
    case "red": return HudSpec.red
    case "green": return HudSpec.green
    case "grey": return HudSpec.grey
    case "dim": return NSColor.white.withAlphaComponent(0.55)
    default: return nil
    }
}

func hudColour(for state: HudState) -> NSColor {
    switch state {
    case .done: return HudSpec.green
    case .error: return HudSpec.red
    case .cancelled: return HudSpec.grey
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

/// The HUD at one moment, drawn by the app's own SwiftUI view.
func hudImage(state: HudState, t: TimeInterval, text: String, colour: Color,
              ring: ColumnRing, turning: Bool = false, scale: CGFloat = 2) -> NSImage {
    // Rendering SwiftUI is main-actor work; the CLI is on the main thread.
    MainActor.assumeIsolated {
        let renderer = ImageRenderer(content: HudBox(
            state: state, t: t, label: text, labelColour: colour,
            target: HudLifecycle.pillSize(for: text), ring: ring, clock: nil, turning: turning))
        renderer.scale = scale
        return renderer.nsImage
            ?? NSImage(size: NSSize(width: HudSpec.fullBox, height: HudSpec.fullBox))
    }
}

/// A ring holding one steady level, for a still of the orb answering a voice.
func voiceRing(level: Float, columns: Int = 140) -> ColumnRing {
    let ring = ColumnRing(capacity: 256)
    for _ in 0..<columns {
        ring.append(Column(low: -level, high: level, rms: level, level: level))
    }
    return ring
}

/// A ring holding a train of syllables, offset by `phase`, so a still shows rings along the sphere.
func syllableRing(phase: Double, columns: Int = 140) -> ColumnRing {
    let ring = ColumnRing(capacity: 256)
    for index in 0..<columns {
        let secondsAgo = Double(columns - index) / HudSpec.columnsPerSecond
        let envelope = abs(sin((secondsAgo + phase) * .pi / 0.25))
        let level = Float(max(0, envelope - 0.2) / 0.8)
        ring.append(Column(low: -level, high: level, rms: level, level: level))
    }
    return ring
}

/// The lifecycle as a contact sheet, drawn by the app's own renderer.
func writeHUDSheet(to path: String) -> Int32 {
    struct Frame { let t: Double; let spin: Float; var note: String = "" }
    struct Row { let title: String; let state: HudState; let text: String; let colour: Color; let frames: [Frame] }

    let rows: [Row] = [
        Row(title: "Done — the box collapses to text + 16 px", state: .done,
            text: defaultHudText(for: .done), colour: Color(nsColor: HudSpec.green),
            frames: [Frame(t: 0.00, spin: 1.10), Frame(t: 0.15, spin: 1.30), Frame(t: 0.30, spin: 1.50),
                     Frame(t: 0.45, spin: 1.70), Frame(t: 0.60, spin: 1.85), Frame(t: 0.70, spin: 1.95)]),
        Row(title: "Error — three throbs, then the box follows", state: .error,
            text: defaultHudText(for: .error), colour: Color(nsColor: HudSpec.red),
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
                             image: hudImage(state: row.state, t: frame.t, text: row.text,
                                             colour: row.colour, ring: IconRenderer.silentRing))
        })
    }, to: path)
}

/// The orb answering a voice: a row of steady levels, and a row of a word being spoken.
func writeVoiceSheet(to path: String) -> Int32 {
    let dim = Color.white.opacity(0.55)

    let levels = SheetRow(
        title: "The orb answers the level (silence → full voice)",
        cells: [0.0, 0.25, 0.5, 0.75, 1.0].map { level in
            SheetCell(caption: String(format: "level %.2f  →  dots ×%.2f", level,
                                      1 + Double(HudSpec.orbGain) * level),
                      image: hudImage(state: .recording, t: 7, text: "", colour: dim,
                                      ring: voiceRing(level: Float(level))))
        })
    let word = SheetRow(
        title: "A word being spoken: 0.8 s of voice, equator (now) to poles (0.8 s ago)",
        cells: [0.0, 0.2, 0.4, 0.6, 0.8, 1.0].map { moment in
            SheetCell(caption: String(format: "%.2f s in", moment),
                      image: hudImage(state: .recording, t: 7, text: "", colour: dim,
                                      ring: syllableRing(phase: moment)))
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

/// One strip of menu bar with a mark on it, tinted the way the system would tint it.
func menuBarCell(_ mark: MenuBarMark, dark: Bool, tint: NSColor? = nil, level: CGFloat = 0,
                 width: CGFloat = 176, height: CGFloat = 44) -> NSImage {
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bar = dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
                   : NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1)
    bar.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    let mark_ = IconRenderer.menuBarImage(mark, pointSize: 18, level: level)
    // A template image carries no colour: the system paints it, white on a dark bar and black on a
    // light one. That is what this reproduces, and how a state colour gets applied.
    let ink = tint ?? (dark ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.82))
    let tinted = NSImage(size: mark_.size)
    tinted.lockFocus()
    mark_.draw(in: NSRect(origin: .zero, size: mark_.size))
    ink.setFill()
    NSRect(origin: .zero, size: mark_.size).fill(using: .sourceIn)
    tinted.unlockFocus()
    tinted.draw(in: NSRect(x: (width - mark_.size.width) / 2, y: (height - mark_.size.height) / 2,
                           width: mark_.size.width, height: mark_.size.height))
    NSGraphicsContext.restoreGraphicsState()
    return tinted
}

/// Every candidate mark, at the size the menu bar really draws it, on a light and a dark bar and in
/// the two states that used to borrow SF Symbols.
func writeMenuBarSheet(_ path: String) -> Int32 {
    let states: [(String, Bool, NSColor?, CGFloat)] = [
        ("light bar", false, nil, 0),
        ("dark bar", true, nil, 0),
        ("recording", true, NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1), 0),
        ("working", true, NSColor(srgbRed: 1.0, green: 0.58, blue: 0.0, alpha: 1), 0),
    ]
    var rows: [SheetRow] = MenuBarMark.allCases.map { mark in
        SheetRow(title: "\(mark.rawValue)  —  \(mark.summary)",
                 cells: states.map { state in
                     SheetCell(caption: state.0,
                               image: menuBarCell(mark, dark: state.1, tint: state.2, level: state.3))
                 })
    }
    // The two marks that answer the voice, which is the point of them: silence to full voice.
    let levels: [CGFloat] = [0.0, 0.25, 0.5, 0.75, 1.0]
    for mark in [MenuBarMark.pulseCore, .levelBars] {
        rows.append(SheetRow(title: "\(mark.rawValue) with the voice, at five levels",
                             cells: levels.map { level in
                                 SheetCell(caption: String(format: "level %.2f", level),
                                           image: menuBarCell(mark, dark: true, tint:
                                               NSColor(srgbRed: 0.4, green: 0.83, blue: 0.81, alpha: 1),
                                                              level: level))
                             }))
    }
    return writeSheet(rows, to: path, cellW: 200, cellH: 64, pad: 30,
                      titleH: 28, captionH: 24, rowGap: 12)
}

/// Draws a contact sheet of pre-rendered frames, two pixels per point.
func writeSheet(_ rows: [SheetRow], to path: String,
                cellW: CGFloat = 152, cellH: CGFloat = 124, pad: CGFloat = 26,
                titleH: CGFloat = 30, captionH: CGFloat = 30, rowGap: CGFloat = 14) -> Int32 {
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

/// Every mark at the sizes an icon is actually seen at — rendered at true pixel size, then
/// drawn enlarged, so a 32 px tile is judged as a 32 px tile and not as a zoomed drawing.
func writeIconSheet(to path: String) -> Int32 {
    let sizes: [CGFloat] = [512, 256, 128, 64, 32, 16]
    let rows = IconMark.allCases.map { mark in
        SheetRow(title: "\(mark.rawValue) — \(mark.summary)",
                 cells: sizes.map { size in
                    SheetCell(caption: "\(Int(size)) px",
                              image: MainActor.assumeIsolated { IconRenderer.image(mark, size: size) })
                 })
    }
    return writeSheet(rows, to: path, cellW: 268, cellH: 268, pad: 30,
                      titleH: 34, captionH: 26, rowGap: 18)
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
        guard argv.count > 2 else { print("usage: Ponte --transcribe <file.wav>"); return 2 }
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
        guard argv.count > 2 else { print("usage: Ponte --bench <file.wav>"); return 2 }
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
                print("  parakeet \(model.shortLabel): not downloaded (Ponte --download \(model.rawValue))")
            }
        }
        return 0

    case "--hud-render":
        guard argv.count > 3, let state = HudState(rawValue: argv[3]) else {
            print("usage: Ponte --hud-render <out.png> <idle|recording|working|done|error|cancelled> [t] [text]")
            return 2
        }
        let t = argv.count > 4 ? (Double(argv[4]) ?? 0) : 0
        let text = argv.count > 5 ? argv[5]
            : (state == .recording ? HudLifecycle.clock(t) : defaultHudText(for: state))
        // An optional colour name, so a state that passes its own colour (the input watcher's amber, the
        // first run's amber) can be proofed as it will really look rather than in the state's default.
        let colour = argv.count > 6 ? hudNamedColour(argv[6]) ?? hudColour(for: state) : hudColour(for: state)
        return writePNG(hudImage(state: state, t: t, text: text,
                                 colour: Color(nsColor: colour),
                                 ring: IconRenderer.silentRing), to: argv[2])

    case "--status-icon":
        guard argv.count > 2 else { print("usage: Ponte --status-icon <out.png> [pt]"); return 2 }
        let pt = argv.count > 3 ? (Double(argv[3]) ?? 18) : 18
        return writePNG(IconRenderer.menuBarImage(pointSize: CGFloat(pt)), to: argv[2])

    case "--icon":
        guard argv.count > 3, let mark = IconMark(rawValue: argv[3]) else {
            print("usage: Ponte --icon <out.png> <orb|core> [size]")
            return 2
        }
        let size = argv.count > 4 ? (Double(argv[4]) ?? 1024) : 1024
        return writePNG(MainActor.assumeIsolated { IconRenderer.image(mark, size: CGFloat(size)) },
                        to: argv[2])

    case "--status-image":
        guard argv.count > 3 else {
            print("usage: Ponte --status-image <out.png> <\(AppState.allCases.map(\.rawValue).joined(separator: "|"))>")
            return 2
        }
        guard let state = AppState(rawValue: argv[3]) else { print("unknown state: \(argv[3])"); return 2 }
        let image = StatusIcon.image(for: state)
        print("state=\(state) template=\(image.isTemplate) tint=\(StatusIcon.tint(for: state)?.description ?? "none") size=\(Int(image.size.width))x\(Int(image.size.height))")
        return writePNG(image, to: argv[2])
    case "--menubar-mark":
        guard argv.count > 3 else {
            print("usage: Ponte --menubar-mark <out.png> <\(MenuBarMark.allCases.map(\.rawValue).joined(separator: "|"))> [pt] [level]")
            return 2
        }
        guard let mark = MenuBarMark(rawValue: argv[3]) else {
            print("unknown mark: \(argv[3])"); return 2
        }
        let pt = argv.count > 4 ? (Double(argv[4]) ?? 18) : 18
        let lvl = argv.count > 5 ? (Double(argv[5]) ?? 0) : 0
        return writePNG(IconRenderer.menuBarImage(mark, pointSize: CGFloat(pt), level: CGFloat(lvl)),
                        to: argv[2])
    case "--menubar-sheet":
        guard argv.count > 2 else { print("usage: Ponte --menubar-sheet <out.png>"); return 2 }
        return writeMenuBarSheet(argv[2])
    case "--icon-sheet":
        guard argv.count > 2 else { print("usage: Ponte --icon-sheet <out.png>"); return 2 }
        return writeIconSheet(to: argv[2])

    case "--hud-voice":
        guard argv.count > 2 else { print("usage: Ponte --hud-voice <out.png>"); return 2 }
        return writeVoiceSheet(to: argv[2])

    case "--hud-strip":
        guard argv.count > 2 else { print("usage: Ponte --hud-strip <out.png>"); return 2 }
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
