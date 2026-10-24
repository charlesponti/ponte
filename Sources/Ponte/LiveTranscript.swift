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
    /// How long to wait before the next pass.
    ///
    /// Proportional to what the last one cost, which does the right thing at both ends: a short take gets a pass
    /// every 400 ms, so the read-out lands a few hundred milliseconds after the words are spoken; a long take
    /// throttles itself instead of spending the whole engine on a courtesy. Holding the engine at about a third
    /// of its capacity is the point — a fixed interval cannot, because a pass costs 0.15 s over three seconds of
    /// audio and about 2.5 s over two minutes.
    ///
    /// The old fixed 1.2 s was the other half of a real complaint: the slower the passes, the bigger each burst,
    /// and the further behind the line fell.
    static let minimumInterval: TimeInterval = 0.35
    /// How many times a pass's cost to wait before the next one. Two keeps the engine at half its capacity —
    /// deliberately tighter than it sounds: the wait *is* the lag, so this is the number that decides how far
    /// behind the read-out runs, and a fixed interval cannot do this job at all when a pass costs 0.15 s over
    /// three seconds of audio and about 2.5 s over two minutes.
    static let costMultiple: TimeInterval = 2
    /// Past this much audio the line is a courtesy and the cost is real, so the passes stop.
    static let longestTake: TimeInterval = 180

    static func interval(sinceLastPass seconds: TimeInterval?) -> TimeInterval {
        guard let seconds, seconds > 0 else { return minimumInterval }
        return max(minimumInterval, seconds * costMultiple)
    }

    /// How much audio a pass covers.
    ///
    /// Not the whole take: a pass over the whole of a growing take costs more every second — measured 0.2 s over
    /// twelve seconds of audio and about 2.5 s over two minutes — so the read-out falls further behind the longer
    /// you talk. A fixed window costs the same at the end of a minute as at the start of one, which is what keeps
    /// the line a fraction of a second behind the voice. The overlap between windows is what makes the stitching
    /// safe: at a pass every half second, consecutive windows share about five and a half of their six seconds.
    static let windowSeconds: TimeInterval = 6

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
        committed = []
        vlog("live transcript: watching \(url.lastPathComponent)")

        // A dispatch timer, not a run-loop one. The run loop only fires timers when something is running it,
        // and there are real cases where nothing is — while a menu is tracking, and in any harness that pumps
        // the main queue without spinning the run loop. The work is a poll of state that belongs to the main
        // thread, so the handler hops there and everything it touches stays single-threaded.
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(30))
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
        guard now.timeIntervalSince(started) < Self.longestTake else {
            vlog("live transcript: past \(Int(Self.longestTake))s of audio, no more live passes")
            stop()
            return
        }
        let interval = Self.interval(sinceLastPass: lastPassCost)
        // No duration check here: the only trustworthy measure of a file that is still being written is its
        // payload, and `snapshot`/`patched` already refuse anything the engine would refuse. Asking AVFoundation
        // instead is how this silently never ran — a WAV whose size fields are zero reads as zero seconds.
        nextPassAt = now.addingTimeInterval(interval)
        run(audio: audio)
    }

    /// The timer ticks four times a second so a change of interval is honoured promptly, while the passes
    /// themselves happen on the schedule `interval(forElapsed:)` describes.
    private var nextPassAt = Date.distantPast
    /// Everything heard so far, stitched from the windows. Each pass delivers this whole thing, so the HUD's own
    /// merge sees a stable prefix and only the tail ever moves.
    private var committed: [String] = []
    /// What the last pass cost, which is what the next interval is derived from.
    private var lastPassCost: TimeInterval?

    private func run(audio url: URL) {
        busy = true
        let mine = generation
        let code = language
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let began = Date()
            defer {
                // The engine's own time, not counting the hop back to the main queue: see the note at the trace.
                let cost = Date().timeIntervalSince(began)
                DispatchQueue.main.async { [weak self] in
                    self?.lastPassCost = cost
                    self?.busy = false
                }
            }
            do {
                let snap = try Self.snapshot(of: url)

                defer { try? FileManager.default.removeItem(at: snap.url) }
                let result = try AsrEngine.transcribe(wav: snap.url,
                                                       parakeetModel: Settings.parakeetModel,
                                                       language: code)
                let window = result.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
                // Timed here, not at the trace: the trace hops to the main queue, where the HUD is drawing sixty
                // times a second, and folding that wait into the cost made the app throttle itself four times
                // harder than the engine needed. The cost decides the next interval, so it has to be the engine's.
                let cost = Date().timeIntervalSince(began)
                DispatchQueue.main.async {
                    guard let self, self.generation == mine else { return }
                    self.onTrace?(String(format: "live: pass %.2fs over %.2fs of window, %d words",
                                         cost, snap.seconds, window.count))
                }
                guard !window.isEmpty else { return }
                DispatchQueue.main.async {
                    guard let self, self.generation == mine else { return }   // the take ended; drop it
                    // Logged whether or not anything was heard: the cost is what the next interval is derived
                    // from, and what decides whether the read-out is fast enough.
                    self.committed = Self.stitch(self.committed, window)
                    self.onText?(self.committed.joined(separator: " "), snap.seconds)
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

    /// Copy the last `seconds` of audio written so far into a readable WAV, with the size fields corrected.
    ///
    /// Also reports how much audio that is, because the reveal rate is measured rather than assumed.
    static func snapshot(of url: URL, lastSeconds seconds: TimeInterval = windowSeconds)
        throws -> (url: URL, seconds: TimeInterval) {
        let data = try Data(contentsOf: url)
        let out = try patched(data, lastSeconds: seconds)
        let payload = min(payloadBytes(of: data), Int(seconds * 32_000))
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("ponte-live-\(UUID().uuidString).wav")
        try out.write(to: dest)
        return (dest, Double(payload) / (16_000 * 2))
    }

    /// The audio payload in bytes, which is what the engine measures its own duration from.
    static func payloadBytes(of data: Data) -> Int { dataRange([UInt8](data))?.count ?? 0 }

    /// Repair the two size fields a WAV in progress leaves at zero: the RIFF size at byte 4 and the `data` chunk
    /// size, wherever that chunk starts. Everything else is left exactly as written.
    static func patched(_ data: Data, lastSeconds seconds: TimeInterval? = nil) throws -> Data {
        var bytes = [UInt8](data)
        guard let range = dataRange(bytes),
              range.count >= Self.minimumSamples else {
            throw PonteError.transcriptionFailed("snapshot has no audio yet")
        }
        if let seconds {
            let want = min(range.count, max(Self.minimumSamples, Int(seconds * 32_000)))
            if want < range.count {
                bytes = Array(bytes[0..<range.lowerBound]) + Array(bytes[(range.upperBound - want)..<range.upperBound])
            }
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

    /// Join a window's words onto what has already been heard.
    ///
    /// Windows overlap, so most of what a pass returns is text already committed and only the new tail is worth
    /// appending. The join is made on the words themselves rather than on timings, and it is allowed to skip the
    /// window's first word: that is the one cut in half by the window's own start, so it is the one least worth
    /// trusting. If no overlap is found at all — a window the engine garbled, say — nothing is appended, because
    /// guessing would either duplicate words or replace settled ones. The next window overlaps this one and
    /// recovers.
    static func stitch(_ committed: [String], _ incoming: [String]) -> [String] {
        guard !committed.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return committed }
        var matched = 0
        var skip = 0
        for start in 0...(incoming.count > 1 ? 1 : 0) {
            var k = min(24, committed.count, incoming.count - start)
            while k >= 1 {
                let tail = committed.suffix(k)
                let head = incoming.dropFirst(start).prefix(k)
                if zip(tail, head).allSatisfy({ normalise($0) == normalise($1) }) { break }
                k -= 1
            }
            if k > matched { matched = k; skip = start }
        }
        guard matched > 0 else { return committed }
        return committed + incoming.dropFirst(skip + matched)
    }

    private static func normalise(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
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
