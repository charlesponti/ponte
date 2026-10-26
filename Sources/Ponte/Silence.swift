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

    /// The end of the speech in `samples`, in sample frames. Nil when nothing in the take rises above the floor.
    ///
    /// Pure, and the only part of this worth testing: everything else is file reading.
    static func lastSpeechFrame(in samples: [Float], sampleRate: Double) -> Int? {
        guard sampleRate > 0 else { return nil }
        let window = max(1, Int(sampleRate * windowSeconds))
        var last: Int?
        var index = 0
        while index + window <= samples.count {
            var energy: Float = 0
            for i in index..<(index + window) { energy += samples[i] * samples[i] }
            if (energy / Float(window)).squareRoot() > floor { last = index + window }
            index += window
        }
        guard let last else { return nil }
        return min(samples.count, last + Int(sampleRate * keep))
    }

    /// Where the speech in a take ends, and how long the take is.
    ///
    /// `end == 0` means the whole take is silent — a microphone that was asleep, or a key pressed by mistake — which is
    /// the case that must keep saying "nothing was recorded" rather than reaching the engine and coming back with a
    /// phantom sentence.
    static func speechEnd(of url: URL) throws -> (end: TimeInterval, duration: TimeInterval) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return (end: 0, duration: 0)
        }
        try file.read(into: buffer)
        let duration = Double(buffer.frameLength) / format.sampleRate
        guard let channel = buffer.floatChannelData?[0] else { return (end: 0, duration: duration) }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard let frame = lastSpeechFrame(in: samples, sampleRate: format.sampleRate) else {
            return (end: 0, duration: duration)
        }
        return (end: Double(frame) / format.sampleRate, duration: duration)
    }

    /// A temporary copy holding only the take's speech, for the engine. The original file is untouched.
    ///
    /// The size fields live four bytes before the payload, so the same patching `LiveTranscript` uses for a take in
    /// progress applies here: zero them and the file reads as zero seconds.
    static func trimmed(url: URL, end: TimeInterval) throws -> URL {
        let data = try Data(contentsOf: url)
        // 16 kHz mono 16-bit is 32 000 bytes a second, and the header is 44.
        let keep = min(data.count, 44 + Int(max(0, end) * 32_000))
        let out = try LiveTranscript.patched(Data(data.prefix(keep)))
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("ponte-trim-\\(UUID().uuidString).wav")
        try out.write(to: target)
        return target
    }
}
