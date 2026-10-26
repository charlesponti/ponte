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

    /// The shortest take worth handing to the engine, which rejects anything under 300 ms of audio.
    static let minimumAudio: TimeInterval = 0.4

    /// The same floor in bytes of 16 kHz mono 16-bit audio. Checking the payload rather than the file size is the
    /// difference between sending a header and sending sound.
    static let minimumSamples = 16_000 * 2 * 3 / 10

    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var busy = false
    private var passIndex = 0
    private var audio: URL?
    private var started = Date()
    private var language = "en"

    /// Called on the main queue with the whole transcript as heard so far (including the parts already shown),
    /// and how much audio the pass covered — the engine's own measure of the take, which is where the speaking
    /// rate comes from.
    var onText: ((String, TimeInterval) -> Void)?
    var onTrace: ((String) -> Void)?
    /// Every pass, timed stage by stage. Goes to the log, not the HUD: it is for diagnosing a slow line.
    var onTiming: ((PassTiming) -> Void)?
    /// The passes have stopped because the take outgrew them. The dictation is unaffected.
    var onPaused: (() -> Void)?

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
        let now = Date()
        // Due first, then busy: asking busy before the schedule logged "skipping" for every tick that was simply
        // not due yet, which buried the real skips — 64 of them in one 24-second take.
        guard now >= nextPassAt else { return }
        guard !busy else {
            onTrace?("live: a pass is still running — skipping this tick")
            return
        }
        guard now.timeIntervalSince(started) < Self.longestTake else {
            // Said out loud as well as in the log: a line that freezes without a word looks like a crash, and this is
            // the one thing the live line does that a person cannot tell from a failure.
            vlog("live transcript: past \(Int(Self.longestTake))s of audio, preview paused — the take continues")
            onPaused?()
            stop()
            return
        }
        let interval = Self.interval(sinceLastPass: lastPassCost)
        // How late the pass is against the schedule it set for itself. The timer ticks four times a second, so
        // anything much beyond that is a main run loop that was busy drawing.
        let late = nextPassAt == .distantPast ? 0 : max(0, now.timeIntervalSince(nextPassAt))
        // No duration check here: the only trustworthy measure of a file that is still being written is its
        // payload, and `snapshot`/`patched` already refuse anything the engine would refuse. Asking AVFoundation
        // instead is how this silently never ran — a WAV whose size fields are zero reads as zero seconds.
        nextPassAt = now.addingTimeInterval(interval)
        run(audio: audio, late: late)
    }

    /// The timer ticks four times a second so a change of interval is honoured promptly, while the passes
    /// themselves happen on the schedule `interval(forElapsed:)` describes.
    private var nextPassAt = Date.distantPast
    /// What the last pass cost, which is what the next interval is derived from.
    private var lastPassCost: TimeInterval?

    private func run(audio url: URL, late: TimeInterval = 0) {
        busy = true
        let mine = generation
        let code = language
        // User-initiated, not utility. This is not background work: it is the line the person is watching while
        // they speak, and a utility queue lets the system deprioritise it — measured 0.4-0.5 s a pass at `.utility`
        // against 0.11 s at the same work from a foreground queue. The throttle that matters is the poll interval,
        // which is already derived from the cost; QoS was throttling in a way nothing could see or bound.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let began = Date()
            defer {
                // The engine's own time, not counting the hop back to the main queue: see the note below.
                let cost = Date().timeIntervalSince(began)
                DispatchQueue.main.async { [weak self] in
                    self?.lastPassCost = cost
                    self?.busy = false
                }
            }
            do {
                let snapshotBegan = Date()
                let snap = try Self.snapshot(of: url)
                let snapshotCost = Date().timeIntervalSince(snapshotBegan)

                defer { try? FileManager.default.removeItem(at: snap.url) }
                let engineBegan = Date()
                let result = try AsrEngine.transcribe(wav: snap.url,
                                                       parakeetModel: Settings.parakeetModel,
                                                       language: code)
                let engineCost = Date().timeIntervalSince(engineBegan)
                let finished = Date()
                let words = result.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
                // Timed here, not at the trace: the trace hops to the main queue, where the HUD is drawing sixty
                // times a second, and folding that wait into the cost made the app throttle itself four times
                // harder than the engine needed. The cost decides the next interval, so it has to be the engine's.
                let cost = finished.timeIntervalSince(began)
                _ = cost
                // How much audio exists *now*, against how much this pass described: the difference is what the
                // person is still waiting to see. Read from the file, because a WAV being written has no duration.
                let onDisk = Self.secondsOnDisk(of: url)
                var timing = PassTiming(
                    index: 0, tickDelay: late, snapshot: snapshotCost, engine: engineCost, hop: 0,
                    covered: snap.seconds, onDisk: onDisk, words: words, chars: result.text.count,
                    tail: Self.tail(of: result.text))

                DispatchQueue.main.async {
                    guard let self, self.generation == mine else { return }   // the take ended; drop it
                    // The hop is the wait for the main queue, measured rather than assumed: it is the one stage
                    // the engine cannot see, and the one that grows when the HUD is drawing a lot.
                    timing.hop = Date().timeIntervalSince(finished)
                    self.passIndex += 1
                    timing.index = self.passIndex
                    self.onTiming?(timing)
                    if !result.text.isEmpty { self.onText?(result.text, snap.seconds) }
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

    /// How much audio is on disk, from the WAV's size: 16 kHz mono 16-bit is 32 000 bytes a second, and the
    /// header is 44. Reading the size is safe while the file is still being written; asking AVFoundation for its
    /// duration is not, which is why this is here at all.
    static func secondsOnDisk(of url: URL) -> TimeInterval {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Double(max(0, size - 44)) / 32_000
    }

    /// The last few words, so the log records what arrived and not only how much.
    static func tail(of text: String, words limit: Int = 5) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).suffix(limit).joined(separator: " ")
    }

    // MARK: - The snapshot

    /// Copy the last `seconds` of audio written so far into a readable WAV, with the size fields corrected.
    ///
    /// Also reports how much audio that is, because the reveal rate is measured rather than assumed.
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
