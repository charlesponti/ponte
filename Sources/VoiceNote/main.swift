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
      VoiceNote --transcribe <file.wav> [--model <name>] [--language <code>]
      VoiceNote --selftest <seconds>
      VoiceNote --devices
      VoiceNote --help

    Models live in \(AppPaths.models.path)
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
        let model = value(of: "--model") ?? Settings.model
        let language = value(of: "--language") ?? Settings.language
        do {
            let result = try Transcriber.transcribe(wav: file, modelName: model, language: language)
            print(result.text)
            FileHandle.standardError.write("(\(String(format: "%.2f", result.seconds))s, model=\(model))\n".data(using: .utf8)!)
            return result.text.isEmpty ? 1 : 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }

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
            let result = try Transcriber.transcribe(wav: url)
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
