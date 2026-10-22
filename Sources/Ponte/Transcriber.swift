import Foundation

/// Runs whisper.cpp over a WAV and returns plain text (no timestamps).
enum Transcriber {
    struct Result {
        let text: String
        let seconds: Double
        var engine: String = "whisper.cpp"
        var confidence: Float? = nil
    }

    static func transcribe(wav: URL,
                           modelName: String = Settings.model,
                           language: String = Settings.language,
                           threads: Int = 8) throws -> Result {
        guard let bin = Whisper.binary() else { throw PonteError.whisperMissing }

        let model = Whisper.modelURL(modelName)
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw PonteError.modelMissing(modelName)
        }

        let started = Date()
        let outBase = wav.deletingPathExtension()
        var args = [
            "-m", model.path,
            "-f", wav.path,
            "-l", language,
            "-t", String(threads),
            "--no-prints",
        ]

        // Newer builds write the .txt themselves; ask for it and also read stdout,
        // so this works across whisper.cpp versions.
        var status: Int32 = 0
        var out = ""
        var err = ""
        let supportsOTxt = supportsFlag(bin, "-otxt")
        if supportsOTxt {
            args += ["-otxt", "-of", outBase.path, "-nt"]
            (status, out, err) = Shell.run(bin.path, args)
        } else {
            (status, out, err) = Shell.run(bin.path, args)
        }

        var text = ""
        let txtFile = URL(fileURLWithPath: outBase.path + ".txt")
        if let fileText = try? String(contentsOf: txtFile, encoding: .utf8), !fileText.isEmpty {
            text = fileText
            try? FileManager.default.removeItem(at: txtFile)
        } else {
            text = out
        }
        text = clean(text)

        if text.isEmpty && status != 0 {
            throw PonteError.transcriptionFailed(err.isEmpty ? "exit \(status)" : err)
        }

        return Result(text: text, seconds: Date().timeIntervalSince(started),
                      engine: "whisper.cpp \(modelName)")
    }

    /// whisper.cpp prints `[00:00:00.000 --> 00:00:05.000]` lines; strip them.
    static func clean(_ raw: String) -> String {
        var lines: [String] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasPrefix("[") , let close = line.firstIndex(of: "]"), line[line.index(after: line.startIndex)..<close].contains("-->") {
                line = String(line[line.index(after: close)...])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            lines.append(line)
        }
        let joined = lines.joined(separator: " ")
        // collapse runs of spaces
        let collapsed = joined.split(separator: " ").joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func supportsFlag(_ bin: URL, _ flag: String) -> Bool {
        let r = Shell.run(bin.path, ["--help"])
        return r.out.contains(flag) || r.err.contains(flag)
    }

    // MARK: - Saving

    @discardableResult
    static func save(transcript: String, audio: URL?, elapsed: TimeInterval, took: Double,
                     engine: String = "whisper.cpp",
                     directory: URL = AppPaths.transcripts,
                     now: Date = Date()) -> URL? {
        guard !transcript.isEmpty else { return nil }
        let file = directory.appendingPathComponent("note-\(AppPaths.stamp(now)).md")
        let duration = String(format: "%.1fs", elapsed)
        let audioField = (Settings.keepAudio ? audio?.lastPathComponent : nil) ?? "(deleted after transcription)"
        let body = """
        ---
        date: \(ISO8601DateFormatter().string(from: now))
        duration: \(duration)
        transcribe_time: \(String(format: "%.1f", took))s
        engine: \(engine)
        language: \(Settings.language)
        audio: \(audioField)
        ---

        \(transcript)
        """
        try? body.write(to: file, atomically: true, encoding: .utf8)

        // Rolling plain-text log, easiest thing to grep.
        let logLine = "## \(AppPaths.stamp(now))  (\(duration))\n\n\(transcript)\n\n"
        let log = directory.appendingPathComponent("all-notes.md")
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(logLine.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? logLine.write(to: log, atomically: true, encoding: .utf8)
        }
        return file
    }
}

// MARK: - Model download (curl, so progress is observable)

final class ModelDownloader {
    private var process: Process?
    private var progressTimer: Timer?
    private(set) var activeName: String?

    var onProgress: ((String) -> Void)?
    var onFinish: ((Result<URL, Error>) -> Void)?

    var isBusy: Bool { process?.isRunning ?? false }

    func download(_ name: String) {
        guard process?.isRunning != true else { return }
        let dest = Whisper.modelURL(name)
        let part = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = [
            "-fL", "--retry", "3", "-o", part.path,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name)",
        ]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch {
            onFinish?(.failure(error))
            return
        }
        process = p
        activeName = name
        vlog("model download start \(name)")

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let p = self.process else { return }
            let attrs = try? FileManager.default.attributesOfItem(atPath: part.path)
            let size = (attrs?[.size] as? Int) ?? 0
            self.onProgress?(String(format: "downloading %@ — %.0f MB", name, Double(size) / 1_048_576))
            if !p.isRunning {
                self.progressTimer?.invalidate()
                self.progressTimer = nil
                self.process = nil
                self.activeName = nil
                if p.terminationStatus == 0 {
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.moveItem(at: part, to: dest)
                        vlog("model download done \(name)")
                        self.onFinish?(.success(dest))
                    } catch { self.onFinish?(.failure(error)) }
                } else {
                    vlog("model download failed \(name) status=\(p.terminationStatus)")
                    self.onFinish?(.failure(PonteError.modelMissing(name)))
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        progressTimer = t
    }
}
