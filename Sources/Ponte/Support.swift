import Foundation

// MARK: - Paths

enum AppPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let support: URL = {
        let u = home.appendingPathComponent("Library/Application Support/Ponte", isDirectory: true)
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
        let u = home.appendingPathComponent("Documents/Ponte", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// The replacement list for words the engine keeps getting wrong. Plain JSON, editable by hand.
    static let vocabulary = support.appendingPathComponent("vocabulary.json")

    static let log = support.appendingPathComponent("ponte.log")

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
            SettingKey.language: "en",
            SettingKey.autoPaste: true,
            SettingKey.keepAudio: false,
            SettingKey.parakeetModel: ParakeetModel.ultra.rawValue,
        ])
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

enum PonteError: LocalizedError {
    case recordFailed
    case micDenied
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .recordFailed: return "could not start recording"
        case .micDenied: return "microphone access denied"
        case .transcriptionFailed(let s): return "transcription failed: \(s)"
        }
    }
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
        run(tn.path, ["-title", title, "-message", message, "-group", "ponte"])
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
