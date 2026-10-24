import XCTest
@testable import Ponte

final class LiveTranscriptTests: XCTestCase {

    /// What the recorder's file looks like mid-take with the canonical header: `fmt ` declared and sized, extra
    /// chunks optional, both size fields still zero.
    private func midWriteWAV(payload: Int, extraChunk: Bool = false) -> [UInt8] {
        var bytes = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)
        bytes += Array("fmt ".utf8) + [16, 0, 0, 0] + Array(repeating: 0, count: 16)
        if extraChunk { bytes += Array("LIST".utf8) + [4, 0, 0, 0] + Array("INFO".utf8) }
        bytes += Array("data".utf8) + [0, 0, 0, 0]
        bytes += Array(repeating: 7, count: payload)
        return bytes
    }

    private func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    // MARK: - How often to look

    func testTheIntervalFollowsWhatAPassCosts() {
        // Cheap over short audio, so the read-out is nearly live; the same law throttles a long take rather than
        // spending the whole engine on a courtesy. Holding the engine near a third of its capacity is the point.
        XCTAssertEqual(LiveTranscript.interval(sinceLastPass: nil), LiveTranscript.minimumInterval)
        XCTAssertEqual(LiveTranscript.interval(sinceLastPass: 0.15), 0.35, accuracy: 1e-9, "the floor")
        XCTAssertEqual(LiveTranscript.interval(sinceLastPass: 0.2), 0.4, accuracy: 1e-9)
        XCTAssertEqual(LiveTranscript.interval(sinceLastPass: 1.0), 2.0, accuracy: 1e-9)
        // No cap: the wait is the lag, so it is allowed to grow with the engine's own cost. What is bounded is
        // the duty cycle — a pass may take up to half the time between passes.
        XCTAssertEqual(LiveTranscript.interval(sinceLastPass: 3.0), 6.0, accuracy: 1e-9)
    }

    /// The first words have to show up quickly: a pass over three quarters of a second of audio costs about
    /// 0.15 s, so at the floor the line lands well inside the first second of speech.
    func testTheReadOutStartsWithinTheFirstSecond() {
        // The first pass runs once the floor has elapsed, over three quarters of a second of audio that costs
        // about 0.15 s: so words reach the line inside the first second of speech.
        XCTAssertEqual(LiveTranscript.interval(sinceLastPass: nil), 0.35)
        XCTAssertLessThan(LiveTranscript.minimumInterval + 0.15, 0.6)
    }

    func testThePassesStopOnAVeryLongTake() {
        XCTAssertGreaterThan(LiveTranscript.longestTake, 60)
        XCTAssertLessThan(LiveTranscript.longestTake, 600)
    }

    func testTheShortestPassWorthMaking() {
        XCTAssertGreaterThan(LiveTranscript.minimumAudio, 0.3, "the engine refuses anything shorter")
    }

    // MARK: - The header repair

    func testAMidWriteHeaderIsRepaired() throws {
        let fake = midWriteWAV(payload: 32_000)          // one second of 16 kHz mono 16-bit
        let patched = try LiveTranscript.patched(Data(fake))
        let bytes = [UInt8](patched)
        XCTAssertEqual(u32(bytes, 4), bytes.count - 8, "the RIFF size must describe the whole file")
        let range = try XCTUnwrap(LiveTranscript.dataRange(bytes))
        XCTAssertEqual(range.lowerBound, 44, "the payload follows a canonical 44-byte header")
        XCTAssertEqual(u32(bytes, 40), bytes.count - 44, "the data size field sits at 40, before the payload")
        XCTAssertEqual(Array(bytes[44..<48]), [7, 7, 7, 7], "the first samples must be untouched")
    }

    func testAHeaderWithNoSoundInItIsRefused() {
        // 48 bytes of header: enough to look like a file, not enough to be one. The engine's own floor is 300 ms,
        // and a snapshot that ignores it produces an error on every tick instead of a transcript.
        let headerOnly = Data(midWriteWAV(payload: 0))
        XCTAssertThrowsError(try LiveTranscript.patched(headerOnly)) { error in
            XCTAssertTrue("\(error)".contains("no audio"), "the message should say why (\(error))")
        }
    }

    func testABrieflyRecordedTakeIsStillTooShort() {
        let brief = Data(midWriteWAV(payload: 3_200))    // 100 ms
        XCTAssertThrowsError(try LiveTranscript.patched(brief))
    }

    func testTheAudioChunkIsFoundAfterOtherChunks() {
        let bytes = midWriteWAV(payload: 64, extraChunk: true)
        let range = LiveTranscript.dataRange(bytes)
        XCTAssertEqual(range?.lowerBound, 56, "the payload starts after the LIST chunk and the data size field")
        XCTAssertEqual(range?.count, 64)
    }

    // MARK: - Stitching windows

    func testTheFirstWindowIsTheTranscript() {
        XCTAssertEqual(LiveTranscript.stitch([], ["the", "quick"]), ["the", "quick"])
    }

    func testAWindowIsJoinedWhereItOverlaps() {
        let committed = ["the", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog"]
        let window = ["over", "the", "lazy", "dog", "and", "keeps", "running"]
        XCTAssertEqual(LiveTranscript.stitch(committed, window),
                       ["the", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog",
                        "and", "keeps", "running"])
    }

    /// A window's own start cuts audio mid-word, so its first word is the fragment least worth trusting and the
    /// committed version wins instead.
    func testTheWindowsFirstWordIsNotTrusted() {
        XCTAssertEqual(LiveTranscript.stitch(["the", "quick", "brown", "fox"], ["th", "quick", "brown", "fox", "jumps"]),
                       ["the", "quick", "brown", "fox", "jumps"])
    }

    func testCaseAndPunctuationDoNotStopTheJoin() {
        XCTAssertEqual(LiveTranscript.stitch(["The", "quick", "brown", "fox"], ["the", "quick,", "brown", "fox", "jumps"]),
                       ["The", "quick", "brown", "fox", "jumps"])
    }

    /// No overlap is not a licence to guess: appending would duplicate words and replacing would drop settled ones,
    /// so the transcript stands still and the next window — which overlaps this one — recovers.
    func testAWindowThatOverlapsNothingKeepsWhatWeHave() {
        let committed = ["the", "quick", "brown", "fox"]
        XCTAssertEqual(LiveTranscript.stitch(committed, ["something", "entirely", "else"]), committed)
    }

    // MARK: - The window itself

    /// The snapshot carries one window of audio, not the whole take, and says so in its size fields.
    func testASnapshotCarriesOneWindowOfAudio() throws {
        let data = Data(midWriteWAV(payload: 32_000 * 20))       // twenty seconds
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ponte-window-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)

        let (url, seconds) = try LiveTranscript.snapshot(of: file, lastSeconds: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(seconds, 6, accuracy: 0.01, "a pass should cover one window, not the take")

        let out = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(LiveTranscript.dataRange(out)?.count, 32_000 * 6)
        XCTAssertEqual(u32(out, 4), out.count - 8, "the RIFF size must describe the snapshot")
        XCTAssertEqual(u32(out, 40), out.count - 44, "and the data size its payload")
    }
}
