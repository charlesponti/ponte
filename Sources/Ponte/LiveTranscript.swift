import AVFoundation
import Foundation

/// Runs the engine over the audio recorded so far, *while* it is still being recorded, so the HUD can show words
/// as they are spoken.
///
/// Two things make this work, both established by experiment rather than assumption:
///
/// - **A WAV being written has zero in its size fields.** The recorder fills them in when it closes the file, so
///   mid-take the header claims nothing and the engine refuses it outright: *"Invalid audio data provided. Must be
///   at least 300ms of 16kHz audio."* Copying the bytes written so far and patching the RIFF and `data` sizes
///   produces a file it transcribes correctly — verified against a take that was still recording.
/// - **Only one pass may be in flight.** The engine is shared with the final transcription, so a queue of live
///   passes would delay the result the user is actually waiting for. A tick that finds a pass already running is
///   skipped, which also keeps the live work bounded to a single pass however long the take runs.
final class LiveTranscript {
    /// How often to look, or nil once a take is long enough that the line is a courtesy rather than a read-out.
    /// The engine's cost grows with the audio — 0.59 s for eight seconds, about 2.5 s for two minutes — so the
    /// interval stretches to stay a small fraction of the take rather than competing with it.
    static func interval(forElapsed elapsed: TimeInterval) -> TimeInterval? {
        switch elapsed {
        case ..<20: return 1.2
        case ..<60: return 2.0
        default: return nil
        }
    }

    /// The shortest take worth handing to the engine, which rejects anything under 300 ms of audio.
    static let minimumAudio: TimeInterval = 0.4

    /// The same floor in bytes of 16 kHz mono 16-bit audio. Checking the payload rather than the file size is the
    /// difference between sending a header and sending sound.
    static let minimumSamples = 16_000 * 2 * 3 / 10

    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var busy = false
    private var audio: URL?
    private var started = Date()
    private var language = "en"

    /// Called on the main queue with the whole transcript as heard so far (including the parts already shown),
    /// and how much audio the pass covered — the engine's own measure of the take, which is where the speaking
    /// rate comes from.
    var onText: ((String, TimeInterval) -> Void)?
    var onTrace: ((String) -> Void)?

    var isRunning: Bool { timer != nil }

    func start(audio url: URL, language code: String) {
        stop()
        audio = url
        language = code
        started = Date()
        vlog("live transcript: watching \(url.lastPathComponent)")

        // A dispatch timer, not a run-loop one. The run loop only fires timers when something is running it,
        // and there are real cases where nothing is — while a menu is tracking, and in any harness that pumps
        // the main queue without spinning the run loop. The work is a poll of state that belongs to the main
        // thread, so the handler hops there and everything it touches stays single-threaded.
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(60))
        t.setEventHandler { [weak self] in DispatchQueue.main.async { self?.tick() } }
        t.resume()
        timer = t
    }

    /// Stop looking, and arrange for anything already in flight to be ignored. The pass itself cannot be
    /// interrupted — `AsrManager` offers no cancellation — which is why the interval is never shorter than the
    /// work it schedules.
    func stop() {
        timer?.cancel()
        timer = nil
        generation += 1
        audio = nil
    }

    private func tick() {
        guard let audio else { return }
        guard !busy else {
            onTrace?("live: a pass is still running — skipping this tick")
            return
        }
        let now = Date()
        guard now >= nextPassAt else { return }
        let elapsed = now.timeIntervalSince(started)
        guard let interval = Self.interval(forElapsed: elapsed) else {
            vlog("live transcript: past a minute, no more live passes")
            stop()
            return
        }
        // No duration check here: the only trustworthy measure of a file that is still being written is its
        // payload, and `snapshot`/`patched` already refuse anything the engine would refuse. Asking AVFoundation
        // instead is how this silently never ran — a WAV whose size fields are zero reads as zero seconds.
        nextPassAt = now.addingTimeInterval(interval)
        run(audio: audio)
    }

    /// The timer ticks four times a second so a change of interval is honoured promptly, while the passes
    /// themselves happen on the schedule `interval(forElapsed:)` describes.
    private var nextPassAt = Date.distantPast

    private func run(audio url: URL) {
        busy = true
        let mine = generation
        let code = language
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { DispatchQueue.main.async { self?.busy = false } }
            let started = Date()
            do {
                let snap = try Self.snapshot(of: url)
                DispatchQueue.main.async { self?.onTrace?(String(format: "live: pass over %.2fs of audio", snap.seconds)) }
                defer { try? FileManager.default.removeItem(at: snap.url) }
                let result = try AsrEngine.transcribe(wav: snap.url,
                                                       parakeetModel: Settings.parakeetModel,
                                                       language: code)
                guard !result.text.isEmpty else { return }
                let took = Date().timeIntervalSince(started)
                DispatchQueue.main.async {
                    guard let self, self.generation == mine else { return }   // the take ended; drop it
                    self.onTrace?(String(format: "live pass %.2fs over %.2fs of audio", took, snap.seconds))
                    self.onText?(result.text, snap.seconds)
                }
            } catch {
                // A live pass is an optimisation. If it fails, the final transcription is unaffected and the
                // line simply does not fill — so this is a trace, not an error.
                DispatchQueue.main.async {
                    guard let self, self.generation == mine else { return }
                    self.onTrace?("live pass failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - The snapshot

    /// Copy the audio written so far into a readable WAV: same bytes, corrected size fields. Also reports how
    /// much audio that is, because the reveal rate is measured from the take rather than assumed.
    static func snapshot(of url: URL) throws -> (url: URL, seconds: TimeInterval) {
        let data = try Data(contentsOf: url)
        let out = try patched(data)
        let payload = payloadBytes(of: data)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("ponte-live-\(UUID().uuidString).wav")
        try out.write(to: dest)
        return (dest, Double(payload) / (16_000 * 2))
    }

    /// The audio payload in bytes, which is what the engine measures its own duration from.
    static func payloadBytes(of data: Data) -> Int { dataRange([UInt8](data))?.count ?? 0 }

    /// Repair the two size fields a WAV in progress leaves at zero: the RIFF size at byte 4 and the `data` chunk
    /// size, wherever that chunk starts. Everything else is left exactly as written.
    static func patched(_ data: Data) throws -> Data {
        var bytes = [UInt8](data)
        guard let range = dataRange(bytes),
              range.count >= Self.minimumSamples else {
            throw PonteError.transcriptionFailed("snapshot has no audio yet")
        }
        func writeUInt32(_ value: Int, at offset: Int) {
            let v = UInt32(value)
            bytes[offset] = UInt8(v & 0xFF)
            bytes[offset + 1] = UInt8((v >> 8) & 0xFF)
            bytes[offset + 2] = UInt8((v >> 16) & 0xFF)
            bytes[offset + 3] = UInt8((v >> 24) & 0xFF)
        }
        writeUInt32(bytes.count - 8, at: 4)                     // RIFF size
        // The size field lives four bytes *before* the payload: `data`＋size＋samples. Writing it at the
        // payload's own offset overwrote the first two samples — which the engine then heard as a click.
        writeUInt32(bytes.count - range.lowerBound, at: range.lowerBound - 4)
        return Data(bytes)
    }

    /// Where the audio payload starts: the first byte after the `data` chunk's size field.
    static func dataRange(_ bytes: [UInt8]) -> Range<Int>? {
        let marker: [UInt8] = Array("data".utf8)
        guard bytes.count > 8 else { return nil }
        var i = 12
        while i + 8 <= bytes.count {
            if Array(bytes[i..<(i + 4)]) == marker {
                let size = Int(bytes[i + 4]) | Int(bytes[i + 5]) << 8 | Int(bytes[i + 6]) << 16 | Int(bytes[i + 7]) << 24
                let start = i + 8
                let end = min(bytes.count, size > 0 ? start + size : bytes.count)
                return start..<max(start, end)
            }
            // Skip to the next chunk, whose size is the four bytes after its name.
            let size = Int(bytes[i + 4]) | Int(bytes[i + 5]) << 8 | Int(bytes[i + 6]) << 16 | Int(bytes[i + 7]) << 24
            i += 8 + max(0, size)
            if size == 0 { i += 1 }
        }
        return nil
    }
}
