import AVFoundation
import Foundation

/// Where the speech in a take ends.
///
/// People stop talking before they let go of the key — a second or two of deciding whether they are done — and that
/// dead air goes to the engine: it costs time, occasionally comes back as a phantom word, and on a short take it is a
/// meaningful share of the audio.
///
/// The take itself is never touched. The WAV stays the record of what was said, the note keeps its duration and the
/// HUD keeps its clock; this only decides how much of the file is sent for transcription.
enum Silence {
    /// Samples quieter than this count as silence. −48 dBFS: a little above the built-in microphone's noise floor and
    /// well below speech.
    static let floor: Float = 0.004
    /// How much audio must be quiet to count as a gap. 20 ms — shorter than the gap inside a word, longer than a click.
    static let windowSeconds: TimeInterval = 0.02
    /// How much is kept after the last speech, so the release of the final word is not cut off mid-consonant.
    static let keep: TimeInterval = 0.15

    /// How many of the windows around a candidate must also be loud for it to count. A click is one window; a word
    /// is several. Without this a recording's own start-up transient decided where the speech began, at 0.13 s in a
    /// take that had two seconds of room before anyone spoke.
    static let sustained = 3
    /// How many windows are looked at when judging that.
    static let reach = 5

    /// The loudness of each window, in RMS.
    static func windowLevels(in samples: [Float], sampleRate: Double) -> [Float] {
        guard sampleRate > 0 else { return [] }
        let window = max(1, Int(sampleRate * windowSeconds))
        var levels: [Float] = []
        var index = 0
        while index + window <= samples.count {
            var energy: Float = 0
            for i in index..<(index + window) { energy += samples[i] * samples[i] }
            levels.append((energy / Float(window)).squareRoot())
            index += window
        }
        return levels
    }

    /// What counts as speech: the absolute floor, or four times the room's own quiet tenth, whichever is higher.
    ///
    /// A fixed floor is right for a silent file and useless in a real room, where the noise sits wherever the room
    /// decides. Four times the quiet tenth is roughly +12 dB above the room, which noise rarely clears and speech
    /// usually does by far.
    static func threshold(levels: [Float]) -> Float {
        guard !levels.isEmpty else { return floor }
        let quiet = levels.sorted()[levels.count / 10]
        let peak = levels.max() ?? 0
        // With nothing appreciably quieter than the loudest window there is no room to measure — the take is either
        // all speech or all noise — and the absolute floor decides. Scaling from the quiet tenth in that case would
        // put the threshold above the speech itself and find nothing at all.
        guard peak > quiet * 2 else { return floor }
        return max(floor, quiet * 4)
    }

    /// Whether window `index` is loud and stays loud for a moment.
    private static func isSpeech(_ levels: [Float], at index: Int, above limit: Float) -> Bool {
        guard index < levels.count, levels[index] > limit else { return false }
        let end = min(levels.count, index + reach)
        return levels[index..<end].count(where: { $0 > limit }) >= min(sustained, end - index)
    }

    /// The end of the speech in `samples`, in sample frames. Nil when nothing in the take rises above the room.
    ///
    /// Pure, and the only part of this worth testing: everything else is file reading.
    static func lastSpeechFrame(in samples: [Float], sampleRate: Double) -> Int? {
        let levels = windowLevels(in: samples, sampleRate: sampleRate)
        guard !levels.isEmpty else { return nil }
        let limit = threshold(levels: levels)
        guard let last = levels.indices.last(where: { isSpeech(levels, at: $0, above: limit) }) else {
            return nil
        }
        let window = max(1, Int(sampleRate * windowSeconds))
        let end = (last + 1) * window
        return min(samples.count, end + Int(sampleRate * keep))
    }

    /// Where the speech in `samples` starts, in sample frames. Nil when nothing rises above the floor.
    static func firstSpeechFrame(in samples: [Float], sampleRate: Double) -> Int? {
        let levels = windowLevels(in: samples, sampleRate: sampleRate)
        guard !levels.isEmpty else { return nil }
        let limit = threshold(levels: levels)
        guard let first = levels.indices.first(where: { isSpeech(levels, at: $0, above: limit) }) else {
            return nil
        }
        // Back off a little so the breath before the first syllable is not clipped off the front.
        let window = max(1, Int(sampleRate * windowSeconds))
        return max(0, first * window - Int(sampleRate * keep))
    }

    /// Where the speech in a take starts and ends, and how long the take is.
    ///
    /// `end == 0` means the whole take is silent — a microphone that was asleep, or a key pressed by mistake — which is
    /// the case that must keep saying "nothing was recorded" rather than reaching the engine and coming back with a
    /// phantom sentence.
    static func speechRange(of url: URL) throws -> (start: TimeInterval, end: TimeInterval, duration: TimeInterval) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return (start: 0, end: 0, duration: 0)
        }
        try file.read(into: buffer)
        let duration = Double(buffer.frameLength) / format.sampleRate
        guard let channel = buffer.floatChannelData?[0] else { return (start: 0, end: 0, duration: duration) }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard let start = firstSpeechFrame(in: samples, sampleRate: format.sampleRate),
              let end = lastSpeechFrame(in: samples, sampleRate: format.sampleRate) else {
            return (start: 0, end: 0, duration: duration)
        }
        return (start: Double(start) / format.sampleRate, end: Double(end) / format.sampleRate,
                duration: duration)
    }

    /// Kept for the trailing-only callers and tests.
    static func speechEnd(of url: URL) throws -> (end: TimeInterval, duration: TimeInterval) {
        let range = try speechRange(of: url)
        return (end: range.end, duration: range.duration)
    }

    /// A temporary copy holding only the take's speech, for the engine. The original file is untouched.
    ///
    /// The size fields live four bytes before the payload, so the same patching `LiveTranscript` uses for a take in
    /// progress applies here: zero them and the file reads as zero seconds.
    static func trimmed(url: URL, start: TimeInterval = 0, end: TimeInterval) throws -> URL {
        let data = try Data(contentsOf: url)
        // 16 kHz mono 16-bit is 32 000 bytes a second, and the header is 44.
        let from = min(data.count, 44 + Int(max(0, start) * 32_000))
        let to = min(data.count, 44 + Int(max(start, end) * 32_000))
        // The header stays; only the payload between the two cuts is kept, and `patched` rewrites its sizes.
        let out = try LiveTranscript.patched(Data(data.prefix(44)) + Data(data[from..<max(from, to)]))
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("ponte-trim-\\(UUID().uuidString).wav")
        try out.write(to: target)
        return target
    }
}
