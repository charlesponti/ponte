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
        XCTAssertEqual(made.fresh, 5)
        // Every one of those words was spoken before it arrived, so the reveal owes nothing: the figure is how long
        // the last word must still wait, not how long pacing would take.
        XCTAssertEqual(made.reveal, 0, accuracy: 1e-9)
    }

    func testWordsAheadOfTheirSpokenMomentAreHeldBackAndSaidSo() {
        var live = LiveText()
        // Ten words inside one second of audio: the tail was spoken later than it arrived, so the line holds it and
        // the log must report how long for.
        let report = try! XCTUnwrap(
            live.absorb((0..<10).map { "w\($0)" }.joined(separator: " "), seconds: 1, at: 1))
        XCTAssertGreaterThan(report.reveal, 0, "a word ahead of its spoken moment is waited on")
    }

    func testASecondSnapshotOfTheSameWordsSettlesThem() {
        var live = LiveText()
        _ = live.absorb("one two three", seconds: 1.2, at: 1.2)
        let second = try! XCTUnwrap(live.absorb("one two three", seconds: 1.2, at: 1.4))
        XCTAssertEqual(second.words, 3)
        XCTAssertEqual(second.stable, 3, "a repeated snapshot settles the prefix rather than changing it")
        XCTAssertEqual(second.fresh, 0)
    }

    func testARevisionDoesNotRestartTheWordsThatSurvivedIt() {
        var live = LiveText()
        _ = live.absorb("the quick brown fox jumps", seconds: 2, at: 2)
        let before = (0..<5).map { live.arrival($0) }
        // A later snapshot capitalises one word and adds another: this is the shape that used to restamp the whole
        // tail and demand twelve seconds of animation for words already on screen.
        _ = live.absorb("the quick Brown fox jumps over", seconds: 3, at: 3)
        XCTAssertEqual(live.arrival(0), before[0])
        XCTAssertEqual(live.arrival(2), before[2], "a capital is not a new word, so it must not animate again")
        XCTAssertEqual(live.arrival(4), before[4], "a revision earlier in the line must not restamp what follows")
        XCTAssertEqual(live.arrival(5), 3, "the genuinely new word arrived now")
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
