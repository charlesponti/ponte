import Foundation

/// The result of a transcription, and the note format it is written into.
///
/// The child process that used to live here — whisper.cpp, driven through `Shell.run` — is gone. Transcription
/// now happens in-process on the Neural Engine; see `ParakeetEngine` and `AsrEngine`.
enum Transcriber {
    struct Result {
        let text: String
        let seconds: Double
        var engine: String = "parakeet"
        var confidence: Float? = nil
    }

    // MARK: - Saving

    @discardableResult
    static func save(transcript: String, audio: URL?, elapsed: TimeInterval, took: Double,
                     engine: String = "parakeet",
                     directory: URL = AppPaths.transcripts,
                     now: Date = Date()) throws -> URL? {
        guard !transcript.isEmpty else { return nil }
        // The timestamp keeps names sortable; the UUID prevents two fast or concurrent takes from replacing one
        // another when they finish in the same second.
        let file = directory.appendingPathComponent("note-\(AppPaths.stamp(now))-\(UUID().uuidString).md")
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
        try body.write(to: file, atomically: true, encoding: .utf8)

        // Rolling plain-text log, easiest thing to grep.
        let logLine = "## \(AppPaths.stamp(now))  (\(duration))\n\n\(transcript)\n\n"
        let log = directory.appendingPathComponent("all-notes.md")
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            if let data = logLine.data(using: .utf8) { handle.write(data) }
            try? handle.close()
        } else {
            try? logLine.write(to: log, atomically: true, encoding: .utf8)
        }
        return file
    }
}

// Whisper's model downloader lived here: a curl process writing into a Ponte support directory, with a timer
// polling its size for the menu. Parakeet's models are fetched by FluidAudio into its own cache, behind the
// readiness state, so none of this is needed.
