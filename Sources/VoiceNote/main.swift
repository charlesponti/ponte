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
