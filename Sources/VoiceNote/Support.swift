import Foundation

// MARK: - Paths

enum AppPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let support: URL = {
        let u = home.appendingPathComponent("Library/Application Support/VoiceNote", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let models: URL = {
        let u = support.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let audio: URL = {
        let u = support.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let transcripts: URL = {
        let u = home.appendingPathComponent("Documents/VoiceNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let log = support.appendingPathComponent("voicenote.log")

    static func stamp(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: d)
    }
}

// MARK: - Settings

enum SettingKey {
    static let model = "model"
    static let language = "language"
    static let autoPaste = "autoPaste"
    static let keepAudio = "keepAudio"
    static let hotKeyCode = "hotKeyCode"
    static let hotKeyMods = "hotKeyMods"
    static let engine = "engine"
    static let parakeetModel = "parakeetModel"
}

enum Settings {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingKey.model: "ggml-large-v3-turbo.bin",
            SettingKey.language: "en",
            SettingKey.autoPaste: true,
            SettingKey.keepAudio: false,
            SettingKey.engine: AsrEngineKind.parakeet.rawValue,
            SettingKey.parakeetModel: ParakeetModel.ultra.rawValue,
        ])
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: SettingKey.model) ?? "ggml-large-v3-turbo.bin" }
        set { UserDefaults.standard.set(newValue, forKey: SettingKey.model) }
    }
    static var language: String {
        get { UserDefaults.standard.string(forKey: SettingKey.language) ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: SettingKey.language) }
    }
    static var autoPaste: Bool {
        get { UserDefaults.standard.bool(forKey: SettingKey.autoPaste) }
        set { UserDefaults.standard.set(newValue, forKey: SettingKey.autoPaste) }
    }
    static var keepAudio: Bool {
        get { UserDefaults.standard.bool(forKey: SettingKey.keepAudio) }
        set { UserDefaults.standard.set(newValue, forKey: SettingKey.keepAudio) }
    }

    /// Which ASR engine does the work. Default: Parakeet on the Neural Engine.
    static var engine: AsrEngineKind {
        get { AsrEngineKind(rawValue: UserDefaults.standard.string(forKey: SettingKey.engine) ?? "") ?? .parakeet }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingKey.engine) }
    }

    static var parakeetModel: ParakeetModel {
        get { ParakeetModel(rawValue: UserDefaults.standard.string(forKey: SettingKey.parakeetModel) ?? "") ?? .ultra }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: SettingKey.parakeetModel) }
    }

    /// Reads a hotkey number that may be written as a decimal int (`-int 49`) or as
    /// a hex string (`-string 0x31`). Falls back to `def` only when the key is absent —
    /// 0 is a legitimate key code (kVK_ANSI_A), so "unset" must be tested explicitly.
    static func hotKey(_ key: String, default def: UInt32) -> UInt32 {
        switch UserDefaults.standard.object(forKey: key) {
        case let number as Int:
            return UInt32(number)
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("0x"), let value = UInt32(trimmed.dropFirst(2), radix: 16) {
                return value
            }
            if let value = UInt32(trimmed) { return value }
            return def
        default:
            return def
        }
    }
}

// MARK: - Errors

enum VoiceNoteError: LocalizedError {
    case whisperMissing
    case modelMissing(String)
    case recordFailed
    case micDenied
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .whisperMissing: return "whisper-cli not found (brew install whisper-cpp)"
        case .modelMissing(let m): return "model \(m) not found in \(AppPaths.models.path)"
        case .recordFailed: return "could not start recording"
        case .micDenied: return "microphone access denied"
        case .transcriptionFailed(let s): return "transcription failed: \(s)"
        }
    }
}

// MARK: - Whisper binary + models

enum Whisper {
    static func binary() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return Shell.which("whisper-cli") ?? Shell.which("whisper-cpp")
    }

    static func installedModels() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.models.path)) ?? []
        return items.filter { $0.hasSuffix(".bin") }.sorted()
    }

    static func modelURL(_ name: String) -> URL { AppPaths.models.appendingPathComponent(name) }

    /// Known models offered in the menu when not present locally.
    static let downloadable: [(name: String, label: String)] = [
        ("ggml-large-v3-turbo.bin", "large-v3-turbo (best, 1.6 GB)"),
        ("ggml-small.en.bin", "small.en (fast, 466 MB)"),
        ("ggml-base.en.bin", "base.en (tiny, 142 MB)"),
    ]
}

// MARK: - Shell

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return (-1, "", "\(error)") }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    static func which(_ name: String) -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for dir in paths.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    static func notify(_ title: String, _ message: String) {
        guard let tn = which("terminal-notifier") else { return }
        run(tn.path, ["-title", title, "-message", message, "-group", "voicenote"])
    }
}

// MARK: - Logging

func vlog(_ message: String) {
    let line = "[\(AppPaths.stamp())] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: AppPaths.log) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: AppPaths.log)
        }
    }
}
