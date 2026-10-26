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

    // MARK: - Where it starts (#20)

    func testTheStartIsWhereTheSpeechIsLessARelease() {
        let taken = silence(2) + speech(1)
        let start = try! XCTUnwrap(Silence.firstSpeechFrame(in: taken, sampleRate: rate))
        // 2 s of room, less the 0.15 s kept so the breath before the first syllable survives.
        XCTAssertEqual(Double(start) / rate, 1.85, accuracy: 0.06)
    }

    func testSpeechFromTheFirstFrameStartsAtZero() {
        let taken = speech(1)
        XCTAssertEqual(Silence.firstSpeechFrame(in: taken, sampleRate: rate), 0)
    }

    func testASilentTakeHasNoStartEither() {
        XCTAssertNil(Silence.firstSpeechFrame(in: silence(3), sampleRate: rate))
    }

    func testTheRangeIsTheSpeechAndNotTheRoomAroundIt() {
        let taken = silence(1.5) + speech(1) + silence(1.5)
        let start = try! XCTUnwrap(Silence.firstSpeechFrame(in: taken, sampleRate: rate))
        let end = try! XCTUnwrap(Silence.lastSpeechFrame(in: taken, sampleRate: rate))
        XCTAssertEqual(Double(start) / rate, 1.35, accuracy: 0.06)
        XCTAssertEqual(Double(end) / rate, 2.65, accuracy: 0.06)
    }

    func testAStartupClickIsNotTheStartOfSpeech() {
        // One loud window 1 s in, then a second of room, then speech: a real recording's transient.
        let click = [Float](repeating: 0.4, count: 320)
        let taken = silence(1) + click + silence(1) + speech(0.5)
        let start = try! XCTUnwrap(Silence.firstSpeechFrame(in: taken, sampleRate: rate))
        XCTAssertGreaterThan(Double(start) / rate, 1.7,
                             "a click must not decide where the take starts — that is what put the cut at 0.13 s")
    }

    func testANoisyRoomStillFindsTheSpeech() {
        // Noise at twice the absolute floor throughout, with speech 1.5 s in. An absolute floor alone would call the
        // noise speech and never trim; four times the room's quiet tenth does not.
        let noise = (0..<Int(3 * rate)).map { _ in Float.random(in: -0.006...0.006) }
        var taken = noise
        let at = Int(1.5 * rate)
        for i in at..<min(taken.count, at + Int(0.6 * rate)) { taken[i] += 0.2 }
        let start = try! XCTUnwrap(Silence.firstSpeechFrame(in: taken, sampleRate: rate))
        XCTAssertEqual(Double(start) / rate, 1.35, accuracy: 0.1)
    }

    func testNoiseAloneIsStillNotSpeech() {
        let room = (0..<Int(2 * rate)).map { _ in Float.random(in: -0.006...0.006) }
        XCTAssertNil(Silence.firstSpeechFrame(in: room, sampleRate: rate),
                     "the room is not a dictation, however loud it is")
    }

    func testShortTakesAreMeasuredToo() {
        let taken = speech(0.3) + silence(1)
        let end = try! XCTUnwrap(Silence.lastSpeechFrame(in: taken, sampleRate: rate))
        XCTAssertEqual(Double(end) / rate, 0.45, accuracy: 0.06)
    }
}
