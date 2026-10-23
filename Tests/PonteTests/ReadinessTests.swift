import XCTest
@testable import Ponte

/// The first-run gate: whether a dictation can start, and what the app says when it cannot.
///
/// The behaviour this guards is specific. The first hotkey press on a fresh install used to record a take
/// and then wait for a ~613 MB download, which reads as a freeze; the same happened after switching to a
/// model that had not been fetched yet. Declining, with a reason, is the whole point.
final class ReadinessTests: XCTestCase {

    func testOnlyAReadyEngineTakesADictation() {
        XCTAssertTrue(Readiness.ready.allowsDictation)
        XCTAssertFalse(Readiness.preparing(percent: nil, note: "Getting the speech model").allowsDictation)
        XCTAssertFalse(Readiness.preparing(percent: 43, note: "Getting the speech model").allowsDictation)
        XCTAssertFalse(Readiness.failed("Could not fetch the speech model").allowsDictation)
    }

    func testTheMenuSaysWhatIsHappening() {
        XCTAssertEqual(Readiness.ready.menuTitle, "Start Recording")
        XCTAssertEqual(Readiness.preparing(percent: 43, note: "Getting the speech model").menuTitle,
                       "Getting the speech model — 43%")
        XCTAssertEqual(Readiness.preparing(percent: nil, note: "Getting the speech model").menuTitle,
                       "Getting the speech model")
        XCTAssertEqual(Readiness.failed("No speech model installed — pick one under Model").menuTitle,
                       "No speech model installed — pick one under Model")
    }

    /// What the pill says when someone dictates too early — the press the app used to swallow.
    func testDecliningSaysSo() {
        XCTAssertEqual(Readiness.preparing(percent: 43, note: "x").refusalLabel, "Not ready — 43%")
        XCTAssertEqual(Readiness.preparing(percent: nil, note: "x").refusalLabel, "Not yet ready")
        XCTAssertEqual(Readiness.failed("x").refusalLabel, "Not ready")
    }

    /// The square box fits about sixteen characters under the orb at the smallest label size; anything
    /// longer draws outside the squircle. This is the second time that limit has bitten.
    func testTheRefusalFitsUnderTheOrb() {
        for label in [Readiness.preparing(percent: nil, note: "x").refusalLabel,
                      Readiness.preparing(percent: 43, note: "x").refusalLabel,
                      Readiness.failed("x").refusalLabel] {
            XCTAssertLessThanOrEqual(label.count, 16, "\"\(label)\" would overflow the box")
        }
    }

    func testThePercentageComesOutOfTheEnginesProse() {
        XCTAssertEqual(Readiness.percent(in: "Downloading Parakeet models… 43% (12/20 files)"), 43)
        XCTAssertEqual(Readiness.percent(in: "Loading Parakeet models… 100%"), 100)
        XCTAssertNil(Readiness.percent(in: "Loading Parakeet models…"))
        XCTAssertNil(Readiness.percent(in: ""))
        XCTAssertNil(Readiness.percent(in: "1234%"), "three digits, so a stray long number is not read as a percentage")
    }

    func testTheHudOnlyShowsANumberWhileItIsCounting() {
        XCTAssertEqual(Readiness.preparing(percent: 12, note: "x").percent, 12)
        XCTAssertNil(Readiness.preparing(percent: nil, note: "x").percent)
        XCTAssertNil(Readiness.ready.percent)
        XCTAssertNil(Readiness.failed("x").percent)
    }
}
