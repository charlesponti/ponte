import XCTest
@testable import Ponte

/// The line before the first word. It exists so half a second of the engine thinking does not look like a dead app,
/// which only works if it breathes: a static dim word reads as a label, not as work in progress.
final class ListeningLineTests: XCTestCase {

    func testItBreathesAndNeverGoesOut() {
        let values = stride(from: 0.0, through: 3.2, by: 0.05).map { ListeningLine.breath(at: $0) }
        let lowest = try! XCTUnwrap(values.min())
        let highest = try! XCTUnwrap(values.max())
        XCTAssertGreaterThanOrEqual(lowest, 0.8, "the line must never fade away: it is the only thing saying 'live'")
        XCTAssertLessThanOrEqual(highest, 1.0)
        XCTAssertGreaterThan(highest - lowest, 0.15, "a breath that cannot be seen is a static label")
    }

    func testOneBreathTakes1_6Seconds() {
        XCTAssertEqual(ListeningLine.breath(at: 0.4), ListeningLine.breath(at: 2.0), accuracy: 1e-9)
        XCTAssertGreaterThan(abs(ListeningLine.breath(at: 0.4) - ListeningLine.breath(at: 1.2)), 0.1)
    }

    func testItIsAFunctionOfTheClockOnly() {
        // Two calls at the same moment must agree: an animation driven by state would not, and would make a still of
        // the HUD a lie.
        XCTAssertEqual(ListeningLine.breath(at: 1.234), ListeningLine.breath(at: 1.234), accuracy: 0)
    }

    func testTheLabelSaysListeningRatherThanWarning() {
        XCTAssertTrue(HudSpec.listeningLabel.lowercased().contains("listening"))
        // Amber is the app's colour for something actually wrong; waiting for speech is not.
        XCTAssertLessThan(HudSpec.listeningAlpha, 0.5, "the line must be dimmer than the transcript it becomes")
    }
}
