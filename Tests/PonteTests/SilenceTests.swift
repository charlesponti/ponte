import XCTest
@testable import Ponte

/// #17: trailing silence is not sent to the engine, but the take is never shortened. These pin the measurement — the
/// part that decides how much of a dictation the engine sees.
final class SilenceTests: XCTestCase {

    private let rate = 16_000.0

    private func speech(_ seconds: Double, level: Float = 0.2) -> [Float] {
        (0..<Int(seconds * rate)).map { _ in level * sin(Float.random(in: 0...1)) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    func testASilentTakeHasNoSpeech() {
        XCTAssertNil(Silence.lastSpeechFrame(in: silence(2), sampleRate: rate),
                     "a take with nothing in it must reach the \"nothing was recorded\" path, not the engine")
    }

    func testNoiseBelowTheFloorIsNotSpeech() {
        let room = (0..<Int(2 * rate)).map { _ in Float.random(in: -0.002...0.002) }
        XCTAssertNil(Silence.lastSpeechFrame(in: room, sampleRate: rate))
    }

    func testTheEndIsTheEndOfSpeechPlusARelease() {
        let taken = speech(1) + silence(2)
        let end = try! XCTUnwrap(Silence.lastSpeechFrame(in: taken, sampleRate: rate))
        // 1 s of speech, plus 0.15 s kept so the last consonant is not cut off.
        XCTAssertEqual(Double(end) / rate, 1.15, accuracy: 0.05)
    }

    func testSpeechRunningToTheEndIsNotTrimmed() {
        let taken = speech(1.5)
        let end = try! XCTUnwrap(Silence.lastSpeechFrame(in: taken, sampleRate: rate))
        XCTAssertEqual(end, taken.count, "nothing to trim means the whole take is sent")
    }

    func testAGapInTheMiddleDoesNotEndTheTake() {
        let taken = speech(0.5) + silence(0.6) + speech(0.5)
        let end = try! XCTUnwrap(Silence.lastSpeechFrame(in: taken, sampleRate: rate))
        XCTAssertGreaterThan(Double(end) / rate, 1.4, "a pause is not the end of a dictation")
    }

    func testShortTakesAreMeasuredToo() {
        let taken = speech(0.3) + silence(1)
        let end = try! XCTUnwrap(Silence.lastSpeechFrame(in: taken, sampleRate: rate))
        XCTAssertEqual(Double(end) / rate, 0.45, accuracy: 0.06)
    }
}
