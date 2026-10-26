import XCTest
@testable import Ponte

/// #18: the live passes stop at three minutes so a long take does not spend the engine on a courtesy. The dictation
/// carries on, so the line has to say it is paused — a frozen transcript with no explanation is indistinguishable
/// from a crash.
final class PauseNoticeTests: XCTestCase {

    func testNothingIsShownWhenThePassesAreStillRunning() {
        XCTAssertFalse(PauseNoticeLine.isShowing(paused: nil, at: 30))
    }

    func testTheNoticeStaysUpForItsWindowAndThenGoesAway() {
        XCTAssertTrue(PauseNoticeLine.isShowing(paused: 180, at: 180))
        XCTAssertTrue(PauseNoticeLine.isShowing(paused: 180, at: 184.9))
        XCTAssertFalse(PauseNoticeLine.isShowing(paused: 180, at: 185),
                       "the frozen words come back once the notice has been read")
        XCTAssertFalse(PauseNoticeLine.isShowing(paused: 180, at: 240),
                       "a notice that never leaves is a permanent second clock")
    }

    func testPausingIsRecordedOnceAndKeepsTheFirstMoment() {
        var live = LiveText()
        live.pausePreview(at: 180)
        live.pausePreview(at: 200)
        XCTAssertEqual(live.pausedAt, 180, "the line was paused once, at the moment it actually stopped")
    }

    func testTheLabelSaysTheTakeIsStillRunning() {
        let label = HudSpec.pauseNoticeLabel.lowercased()
        XCTAssertTrue(label.contains("paused"))
        XCTAssertTrue(label.contains("recording") || label.contains("still"),
                      "the point of the notice is that the dictation has not stopped")
        // Dim ink, not amber: this is by design, not a fault.
        XCTAssertLessThanOrEqual(HudSpec.listeningAlpha, 0.5)
    }
}
