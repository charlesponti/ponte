import XCTest
@testable import Ponte

/// The live line's diagnostics are only worth having if they can be read: one pass must say where its time went,
/// and a take must total those up. These tests pin the shape of both, because a log line that drops a stage is
/// how a slow line goes undiagnosed for a week.
final class LiveTimingsTests: XCTestCase {

    private var lines: [String] = []

    private func timings() -> LiveTimings {
        lines = []
        return LiveTimings(log: { [weak self] in self?.lines.append($0) })
    }

    private func pass(_ index: Int, engine: TimeInterval = 0.6, covered: TimeInterval = 10,
                      onDisk: TimeInterval = 10.5, hop: TimeInterval = 0.02) -> PassTiming {
        PassTiming(index: index, tickDelay: 0.02, snapshot: 0.004, engine: engine, hop: hop,
                   covered: covered, onDisk: onDisk, words: 18, chars: 96, tail: "and then i said")
    }

    // MARK: - One pass

    func testAPassLineNamesEveryStage() {
        let log = timings()
        log.pass(pass(3))
        let line = try! XCTUnwrap(lines.first)
        for stage in ["pass 3", "late", "snapshot", "engine", "hop", "cover", "disk", "behind", "18w", "96c"] {
            XCTAssertTrue(line.contains(stage), "a pass line must report \(stage): \(line)")
        }
        XCTAssertTrue(line.contains("and then i said"), "the log must show what arrived, not only how much")
    }

    func testBehindIsTheSpeechTheLineHasNotShownYet() {
        XCTAssertEqual(pass(1, covered: 10, onDisk: 12.5).behind, 2.5, accuracy: 1e-9)
        // The file can lag the snapshot by a byte or two; negative lag is not a thing.
        XCTAssertEqual(pass(1, covered: 10, onDisk: 9.9).behind, 0, accuracy: 1e-9)
    }

    // MARK: - The absorb

    func testAbsorbReportsWhatArrivedAndWhatItCostsToShow() {
        var live = LiveText()
        let report = live.absorb("one two three four five", seconds: 2, at: 2)
        let made = try! XCTUnwrap(report)
        XCTAssertEqual(made.words, 5)
        XCTAssertEqual(made.rate, 2.5, accuracy: 1e-9)
        // Nothing is settled on the first snapshot, so every word is still being revealed.
        XCTAssertEqual(made.fresh, 5)
        XCTAssertGreaterThan(made.reveal, 0)
    }

    func testASecondSnapshotOfTheSameWordsSettlesThem() {
        var live = LiveText()
        _ = live.absorb("one two three", seconds: 1.2, at: 1.2)
        let second = try! XCTUnwrap(live.absorb("one two three", seconds: 1.2, at: 1.4))
        XCTAssertEqual(second.words, 3)
        XCTAssertEqual(second.stable, 3, "a repeated snapshot settles the prefix rather than changing it")
        XCTAssertEqual(second.fresh, 0)
    }

    // MARK: - The take

    func testTheSummaryTotalsThePassesAndShowsTheFirstWord() {
        let log = timings()
        log.pass(pass(1, engine: 0.4, covered: 5, onDisk: 6))
        log.pass(pass(2, engine: 0.8, covered: 10, onDisk: 11.2))
        log.absorbed(AbsorbReport(words: 10, fresh: 4, stable: 6, rate: 2.5, reveal: 1.6), mainThread: 0.0009)
        log.firstWord(at: 1.2)

        let summary = log.summary(take: 12.4)
        XCTAssertTrue(summary.contains("take 12.4s"), summary)
        XCTAssertTrue(summary.contains("2 passes"), summary)
        XCTAssertTrue(summary.contains("engine mean 600ms"), summary)
        XCTAssertTrue(summary.contains("engine mean 600ms max 800ms"), summary)
        XCTAssertTrue(summary.contains("behind mean 1.10s"), summary)
        XCTAssertTrue(summary.contains("first word 1.20s"), summary)
    }

    func testTheFirstWordIsOnlyReportedOnce() {
        let log = timings()
        log.firstWord(at: 1.2)
        log.firstWord(at: 3.4)
        XCTAssertEqual(lines.filter { $0.contains("first word shown") }.count, 1)
        XCTAssertTrue(lines[0].contains("1.20s"))
    }

    func testResetClearsTheTake() {
        let log = timings()
        log.pass(pass(1))
        log.absorbed(AbsorbReport(words: 3, fresh: 3, stable: 0, rate: 2.5, reveal: 1.2), mainThread: 0.001)
        log.firstWord(at: 0.9)
        log.reset()

        let fresh = log.summary(take: 2)
        XCTAssertTrue(fresh.contains("0 passes"), fresh)
        XCTAssertTrue(fresh.contains("first word never"), fresh)
        XCTAssertEqual(lines.count, 3, "pass, absorb and first word log; reset itself does not")
    }
}
