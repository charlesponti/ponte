import AppKit
import SwiftUI
import XCTest
@testable import Ponte

/// The square box's internal spacing, measured from what it renders rather than from its constants.
///
/// This exists because every constant looked right and the type still sat too close to the bottom. The
/// block is laid out as *frames*: the orb's frame carries about 8 pt of dots that are too dim to see,
/// and the label's frame carries descender space its glyphs never use, so centring the frames left the
/// text 10 pt from the bottom edge against 15 pt above the orb. Frames are not what anyone sees.
@MainActor
final class HudSpacingTests: XCTestCase {

    private func frame(_ state: HudState, _ t: TimeInterval, _ text: String) -> NSImage {
        hudImage(state: state, t: t, text: text,
                 colour: Color(nsColor: hudColour(for: state)),
                 ring: IconRenderer.silentRing)
    }

    /// Points per pixel of the render. `hudImage` asks `ImageRenderer` for 2x, but the image it hands
    /// back is CGImage-backed and `Probe` redraws it at its own pixel size, which lands at 1 px per point
    /// in-process. Deriving it from the box is exact and survives either behaviour.
    private func scale(of rep: NSBitmapImageRep) -> Double {
        Double(rep.pixelsHigh) / Double(HudSpec.fullBox)
    }

    private func pt(_ pixels: Int, _ rep: NSBitmapImageRep) -> Double {
        Double(pixels) / scale(of: rep)
    }

    func testTheSquareIsTheBoxTheDesignDraws() {
        guard let rep = Probe.bitmap(frame(.recording, 1, "0:07")) else { return XCTFail("no bitmap") }
        XCTAssertEqual(pt(rep.pixelsWide, rep), Double(HudSpec.fullBox), accuracy: 0.5)
        XCTAssertEqual(pt(rep.pixelsHigh, rep), Double(HudSpec.fullBox), accuracy: 0.5)
    }

    /// The complaint, as a test: the type must not be the tightest thing in the box.
    func testTheLabelsBottomClearanceIsGenerous() {
        guard let rep = Probe.bitmap(frame(.recording, 1, "0:07")) else { return XCTFail("no bitmap") }
        let groups = Probe.inkGroups(frame(.recording, 1, "0:07"))
        XCTAssertFalse(groups.isEmpty, "the frame drew no ink at all")
        guard let label = groups.last else { return }
        let belowLabel = pt(rep.pixelsHigh - label.1, rep)
        XCTAssertGreaterThanOrEqual(belowLabel, 16, "the label needs room below it — measured \(belowLabel) pt")
        // Deliberately no comparison against the orb's own top clearance. Beyond its bright core the
        // orb's dots are dim enough that at 1 px per point they do not register at all, so the top of the
        // first band of ink is a different measurement in a 1x render than in the 2x one the command line
        // writes (34 pt against 15). The label's clearance is the thing the complaint was about, and it
        // is exact: pixels from the text's last row to the bottom edge of the box.
        if let first = groups.first, groups.count > 1 {
            let aboveBrightInk = pt(first.0, rep)
            XCTAssertGreaterThanOrEqual(aboveBrightInk, 12, "the orb keeps its headroom — measured \(aboveBrightInk) pt")
        }
    }

    /// The lift is scaled by the collapse, so the pill is spaced exactly as the board draws it: text plus
    /// 16 pt on all four sides, measured here as ~19 pt of glyph clearance, the difference being leading.
    func testThePillIsUntouchedByTheSquaresLift() {
        guard let rep = Probe.bitmap(frame(.done, 0.9, "Pasted ✓")) else { return XCTFail("no bitmap") }
        let groups = Probe.inkGroups(frame(.done, 0.9, "Pasted ✓"))
        XCTAssertEqual(groups.count, 1, "a pill is text and nothing else")
        guard let ink = groups.first else { return }
        let above = pt(ink.0, rep)
        let below = pt(rep.pixelsHigh - ink.1, rep)
        XCTAssertGreaterThanOrEqual(above, 14, "measured \(above) pt above")
        XCTAssertGreaterThanOrEqual(below, 14, "measured \(below) pt below")
        XCTAssertEqual(above, below, accuracy: 2.5, "the pill is symmetric")
    }
}
