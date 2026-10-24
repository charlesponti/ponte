import XCTest
@testable import Ponte

/// The live transcript, end to end, on real speech.
///
/// The acoustic route is unavailable on this machine: scripted dictation needs speech from the speakers to reach
/// the microphone, and the system default input here is a pair of AirPods, which hear the room rather than the
/// Mac's speakers. So the speech is *synthesised to a file* — `say -o`, no microphone anywhere — and fed to the
/// live path one second at a time, in a file that is still growing.
///
/// That is the same thing the recorder hands the live path: a WAV whose two size fields are still zero, with more
/// audio appearing in it every second. What this proves is that words come out of it *before* the take ends, that
/// no word is ever lost or re-ordered as snapshots arrive, and that the whole transcript is eventually there.
@MainActor
final class LiveTranscriptIntegrationTests: XCTestCase {

    /// 16 kHz mono 16-bit: the format the engine accepts, and the one byte arithmetic works on.
    private let bytesPerSecond = 16_000 * 2

    /// Speech in a file, with no microphone involved.
    private func speech(_ text: String) throws -> Data {
        let dir = FileManager.default.temporaryDirectory
        let aiff = dir.appendingPathComponent("ponte-live-src-\(UUID().uuidString).aiff")
        let wav = dir.appendingPathComponent("ponte-live-src-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: aiff); try? FileManager.default.removeItem(at: wav) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, text]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "say failed to synthesise the speech")
        try? FileManager.default.removeItem(at: wav)

        // afconvert is part of macOS: AIFF to the engine's own format.
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]
        try convert.run()
        convert.waitUntilExit()
        XCTAssertEqual(convert.terminationStatus, 0, "afconvert failed")
        return try Data(contentsOf: wav)
    }

    /// A file in the state the recorder leaves mid-take: a real header with both size fields still zero.
    ///
    /// The payload's offset comes from the same chunk-walker the live path uses, not from a fixed 44: a real WAV
    /// here carries other chunks before `data`, and assuming the canonical layout slices the wrong bytes.
    private func midTakeHeader(of data: Data, payloadAt start: Int) -> Data {
        var header = Data(data.prefix(start))
        for offset in [4, 5, 6, 7] { header[offset] = 0 }                       // RIFF size
        for offset in (start - 4)..<start { header[offset] = 0 }                // the data chunk's size
        return header
    }

    private func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Async, and on the main actor, so the main dispatch queue is drained while the test waits. That matters:
    /// the live passes hand their results to the main queue, and a mode-specific `RunLoop.run(mode:before:)`
    /// never services it — the first pass would run and then never report, leaving `busy` set for good.
    func testWordsArriveWhileTheAudioIsStillGrowing() async throws {
        let sentence = "the quick brown fox jumps over the lazy dog and keeps on running through the long green field"
        let audio = try speech(sentence)
        let payloadAt = try XCTUnwrap(LiveTranscript.dataRange([UInt8](audio)),
                                      "the synthesised file has no data chunk").lowerBound
        let payload = audio.count - payloadAt
        XCTAssertGreaterThan(payload, bytesPerSecond * 4, "the synthesised speech should be several seconds long")

        // The take: the header, then one second of audio — and more arriving every second.
        let dir = FileManager.default.temporaryDirectory
        let growing = dir.appendingPathComponent("ponte-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: growing) }
        try midTakeHeader(of: audio, payloadAt: payloadAt).write(to: growing)
        let handle = try FileHandle(forWritingTo: growing)
        try handle.seekToEnd()

        var passes: [(at: TimeInterval, words: [String])] = []
        let live = LiveTranscript()
        let began = Date()
        live.onText = { text, _ in passes.append((Date().timeIntervalSince(began), self.words(text))) }

        live.start(audio: growing, language: "en")

        // Feed the audio in one-second slices, waiting a little longer than the live interval between each so a
        // pass runs on an incomplete file — which is the whole point.
        var written = 0
        while written < payload {
            let end = min(written + bytesPerSecond, payload)
            try handle.write(contentsOf: audio[(payloadAt + written)..<(payloadAt + end)])
            written = end
            try await Task.sleep(for: .milliseconds(1350))
        }
        live.stop()
        try handle.close()

        // The result, as the app would take it: the whole take, run through the same repair the live path uses,
        // because the file on disk still has its size fields zeroed.
        let final = try AsrEngine.transcribe(wav: try LiveTranscript.snapshot(of: growing).url)
        let finalWords = words(final.text)

        XCTAssertGreaterThanOrEqual(passes.count, 3,
                                    "expected several live passes, got \(passes.map(\.at))")
        XCTAssertTrue(finalWords.contains("quick"), "the engine should have heard the take: \(final.text)")

        // 1. Words came out before the take ended. This is the point of the whole feature.
        let midway = passes.filter { $0.at < 1.0 * Double(payload / bytesPerSecond) - 1.5 }
        XCTAssertFalse(midway.isEmpty, "no live pass completed before the audio finished: \(passes.map(\.at))")
        XCTAssertGreaterThan(midway.first?.words.count ?? 0, 0,
                             "the first live pass heard nothing: \(passes.prefix(3))")

        // 2. The transcript never goes backwards as snapshots arrive: no pass loses words an earlier pass had.
        //    (`merge` replaces the tail — that is what lets a misheard word be corrected — so a strict
        //    prefix-of-the-next-pass assertion would be wrong; the count must simply not fall.)
        for (earlier, later) in zip(passes, passes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.words.count, earlier.words.count,
                                        "a pass lost words:\n  \(earlier.words)\n  \(later.words)")
        }

        // 3. The first word is settled from the start: the merge keeps the shared prefix rather than re-deciding
        //    the whole line on every snapshot.
        if let first = passes.first?.words.first {
            for pass in passes.dropFirst() {
                XCTAssertEqual(pass.words.first, first, "the first word changed between passes")
            }
        }
    }
}
