import XCTest
@testable import Ponte
import WaveformCore

/// The input watcher: the rule that decides a take is producing nothing, and the thresholds the
/// measured failures set. A false warning mid-sentence would be worse than none, so the verdict is
/// about the take as a whole rather than the last quarter second.
final class InputWatchTests: XCTestCase {

    private func verdict(_ peaks: [Float], every step: TimeInterval = 0.25) -> InputWatch.Verdict {
        var watch = InputWatch()
        var elapsed: TimeInterval = 0
        for peak in peaks {
            elapsed += step
            _ = watch.observe(peakDB: peak, at: elapsed)
        }
        return watch.verdict
    }

    func testATakeThatHearsNothingSaysSoAfterThreeSeconds() {
        let silent = [Float](repeating: -60, count: 11)          // 2.75 s
        XCTAssertEqual(verdict(silent), .listening, "too early to judge")
        XCTAssertEqual(verdict(silent + [-60]), .noSignal, "three seconds of nothing is no signal")
    }

    func testPausingMidSentenceIsNotAProblem() {
        // A soft start, a pause, then a voice: the take as a whole was heard.
        XCTAssertEqual(verdict([-60, -60, -60, -60, -58, -12, -60, -60, -60, -60, -60, -60]), .listening)
    }

    /// The false positive that live testing caught, kept as a guard.
    ///
    /// A voice that transcribed 64 characters and pasted them perfectly peaked at −30 dBFS, and an
    /// earlier "too quiet" rule at −20 dBFS nagged about it anyway. There is no second warning any more,
    /// because no threshold separates "faint but fine" from "faint and lost" — the two unusable
    /// recordings peaked at −22.5 and −24.1, right among the takes that work.
    func testAUsableQuietVoiceIsNeverWarnedAbout() {
        XCTAssertEqual(verdict([Float](repeating: -30, count: 16)), .listening, "this transcribed perfectly")
        XCTAssertEqual(verdict([Float](repeating: -24.1, count: 16)), .listening, "faint, but no threshold can call it lost")
        XCTAssertEqual(verdict([Float](repeating: -36, count: 16)), .listening, "exactly at the threshold is not a warning")
        XCTAssertEqual(verdict([Float](repeating: -36.1, count: 16)), .noSignal)
    }

    func testAQuietInputThatRecoversIsLeftAlone() {
        var watch = InputWatch()
        var elapsed: TimeInterval = 0
        for _ in 0..<14 { elapsed += 0.25; _ = watch.observe(peakDB: -60, at: elapsed) }
        XCTAssertEqual(watch.verdict, .noSignal)
        elapsed += 0.25
        XCTAssertEqual(watch.observe(peakDB: -9, at: elapsed), .listening, "the verdict clears when the input returns")
    }

    /// Every silence case that was actually measured, at the values it was measured at.
    func testEverySilenceCaseThatWasMeasuredIsCaught() {
        for peak in [Float(-91), -57.1, -50.3, -44.3, -43.7, -39.1] {
            XCTAssertEqual(verdict([Float](repeating: peak, count: 12)), .noSignal,
                           "the \(peak) dBFS recording captured nothing")
        }
        XCTAssertEqual(verdict([Float](repeating: -10, count: 12)), .listening, "a voice near the mic is never warned about")
    }

    func testNoReadingAtAllIsSilence() {
        var watch = InputWatch()
        var elapsed: TimeInterval = 0
        for _ in 0..<14 { elapsed += 0.25; _ = watch.observe(peakDB: nil, at: elapsed) }
        XCTAssertEqual(watch.verdict, .noSignal, "a recorder that hands back nothing is an input with no signal")
    }

    func testThePeakOfAColumnIsItsLoudestSample() {
        XCTAssertEqual(InputWatch.peakDB(Column(low: -0.5, high: 0.25, rms: 0.1)), -6.02, accuracy: 0.01)
        XCTAssertEqual(InputWatch.peakDB(Column(low: 0, high: 0, rms: 0)), InputWatch.silenceFloorDB)
        XCTAssertEqual(InputWatch.peakDB(.silent), InputWatch.silenceFloorDB)
    }

    /// What the HUD is given: short enough to sit under the orb inside the square box.
    func testTheLabelsAreShortEnoughForTheBox() {
        XCTAssertNil(InputWatch.Verdict.listening.label)
        XCTAssertEqual(InputWatch.Verdict.noSignal.label, "Check the mic")
        for verdict in [InputWatch.Verdict.noSignal] {
            XCTAssertLessThan(verdict.label!.count, 20, "\(verdict) would not fit the box")
        }
    }
}
