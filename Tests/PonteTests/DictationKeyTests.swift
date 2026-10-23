import AppKit
import XCTest
@testable import Ponte

/// Esc and Return during a dictation. Two things are worth pinning down: which physical key does
/// what, and that cancelling looks like cancelling — it is neither the green of a paste nor the red of
/// a failure.
final class DictationKeyTests: XCTestCase {

    func testTheEscapeKeyCancels() {
        XCTAssertEqual(DictationKey.escape.meaning, .cancel)
    }

    func testBothReturnsCommit() {
        XCTAssertEqual(DictationKey.enter.meaning, .commit)
        XCTAssertEqual(DictationKey.keypadEnter.meaning, .commit)
    }

    /// The codes themselves, written out: an enum case wired to the wrong key would otherwise still
    /// pass every other assertion in this file.
    func testTheKeysAreTheOnesOnTheKeyboard() {
        XCTAssertEqual(DictationKey.escape.keyCode, 53)
        XCTAssertEqual(DictationKey.enter.keyCode, 36)
        XCTAssertEqual(DictationKey.keypadEnter.keyCode, 76)
    }

    func testTheHintNamesBothKeysOnce() {
        XCTAssertEqual(DictationKey.hints, "Esc cancels · Return finishes")
    }
}

/// The cancelled pill.
final class CancelledHudTests: XCTestCase {
    private let target = CGSize(width: HudLifecycle.pillSize(for: "Cancelled").width,
                                height: HudLifecycle.pillSize(for: "Cancelled").height)

    func testCancelledStartsAsTheFullQuietBox() {
        let g = HudLifecycle.geometry(.cancelled, 0, target: target)
        XCTAssertEqual(g.box.width, HudSpec.fullBox, accuracy: 0.5)
        XCTAssertEqual(g.visual.orb, 1, accuracy: 0.01)
        XCTAssertEqual(g.visual.tint, HudSpec.mint)
    }

    /// It ends on the pill, faded out, and grey — not green.
    func testCancelledCollapsesToThePillInGrey() {
        let end = HudSpec.cancelHold + HudSpec.cancelCollapse
        let g = HudLifecycle.geometry(.cancelled, end, target: target)
        XCTAssertEqual(g.box.width, target.width, accuracy: 1)
        XCTAssertEqual(g.box.height, target.height, accuracy: 1)
        XCTAssertEqual(g.visual.orb, 0.05, accuracy: 0.02)
        XCTAssertEqual(g.visual.alpha, 0, accuracy: 0.02)
        XCTAssertEqual(g.visual.spin, HudSpec.baseSpin, accuracy: 0.15, "the spin ramps down with the orb")

        let tint = g.visual.tint
        XCTAssertEqual(tint.redComponent, tint.greenComponent, accuracy: 0.02, "cancelled is neutral")
        XCTAssertLessThan(tint.greenComponent, 0.7, "and never the green of a paste")
        XCTAssertEqual(tint.blueComponent, HudSpec.grey.blueComponent, accuracy: 0.02)
    }

    /// The HUD is gone from the screen by the end of its life, and gone sooner than a success is.
    func testCancelledHidesItselfAndDoesSoQuietly() {
        XCTAssertEqual(HudLifecycle.lifetime(.cancelled), HudSpec.cancelLife)
        XCTAssertLessThan(HudSpec.cancelLife, HudSpec.doneLife)
        let g = HudLifecycle.geometry(.cancelled, HudSpec.cancelLife, target: target)
        XCTAssertEqual(g.hudAlpha, 0, accuracy: 0.001)
    }

    func testTheLifecycleSaysCancelled() {
        XCTAssertEqual(defaultHudText(for: .cancelled), "Cancelled")
        XCTAssertEqual(hudColour(for: .cancelled), HudSpec.grey)
    }
}
