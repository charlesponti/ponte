import AppKit
import XCTest
@testable import Ponte

/// The floating panel has to hold everything the HUD draws inside it.
///
/// This exists because it did not. The panel was sized for a 104 pt square and the live box is 330 × 156, so the
/// top of the orb fell outside the panel — and a clipped box is invisible in the place you would look for it,
/// which is a still of the box itself. The box draws fine; the panel was too small to show it.
final class HudPanelTests: XCTestCase {

    private let allStates: [HudState] = [.idle, .recording, .working, .loading, .done, .error, .cancelled]

    func testThePanelHoldsEveryBoxAStateDraws() {
        for state in allStates {
            let box = HudLifecycle.fullSize(for: state)
            XCTAssertLessThanOrEqual(box.width, HudSpec.panelSize.width, "\(state) is wider than the panel")
            XCTAssertLessThanOrEqual(box.height, HudSpec.panelSize.height, "\(state) is taller than the panel")
        }
    }

    /// The longest things the HUD ever says, measured the way the pill measures them. A new label that overflows
    /// draws outside the squircle and then outside the panel, with nothing to catch it.
    func testThePanelHoldsTheLongestLabels() {
        let labels = [
            "Microphone access denied — System Settings ▸ Privacy",
            "Nothing was recorded — check the microphone",
            "Copied — press ⌘V",
            "Listening — say something",
            "\(HudSpec.liveBox.width) pt",
        ]
        for label in labels {
            let pill = HudLifecycle.pillSize(for: label)
            XCTAssertLessThanOrEqual(pill.width, HudSpec.panelSize.width, "\"\(label)\" is wider than the panel")
            XCTAssertLessThanOrEqual(pill.height, HudSpec.panelSize.height, "\"\(label)\" is taller than the panel")
        }
    }

    /// The transcript's lane: the clock, the gap, and the line inside the box's own padding.
    func testTheTranscriptLaneFitsTheWideBox() {
        let lane = HudSpec.liveBox.width - HudSpec.boxPadding * 2 - HudSpec.clockWidth - 8
        XCTAssertGreaterThan(lane, 240, "the lane is narrower than a line of speech: \(lane) pt")
        XCTAssertLessThanOrEqual(lane + HudSpec.clockWidth + 8 + HudSpec.boxPadding * 2, HudSpec.liveBox.width)
    }
}
