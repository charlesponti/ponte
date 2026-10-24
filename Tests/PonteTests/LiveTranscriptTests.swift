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

    func testTheIntervalStretchesAsTheEngineCostGrows() {
        XCTAssertEqual(LiveTranscript.interval(forElapsed: 3), 1.2)
        XCTAssertEqual(LiveTranscript.interval(forElapsed: 19.9), 1.2)
        XCTAssertEqual(LiveTranscript.interval(forElapsed: 20), 2.0)
        XCTAssertEqual(LiveTranscript.interval(forElapsed: 59), 2.0)
        XCTAssertNil(LiveTranscript.interval(forElapsed: 60),
                     "past a minute the line is a courtesy, and the engine cost is no longer a small fraction")
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
}
