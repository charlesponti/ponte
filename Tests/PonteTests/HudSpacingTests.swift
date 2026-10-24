import AppKit
import SwiftUI
import XCTest
@testable import Ponte

/// The box's internal spacing, measured from what it renders rather than from its constants.
///
/// This exists because every constant looked right and the type still sat too close to the bottom. The
/// block is laid out as *frames*: the orb's frame carries about 8 pt of dots that are too dim to see,
/// and a label's frame carries descender space its glyphs never use, so centring the frames left the
/// text 10 pt from the bottom edge against 15 pt above the orb. Frames are not what anyone sees.
///
/// The wide box added a second thing to measure: a row of two elements — the clock and one line of live
/// transcript — where the transcript has to reach the box's right padding and stop there.
@MainActor
final class HudSpacingTests: XCTestCase {

    private func frame(_ state: HudState, _ t: TimeInterval, _ text: String,
                       live: LiveText = LiveText(), recordedFor: TimeInterval = 0) -> NSImage {
        hudImage(state: state, t: t, text: text,
                 colour: Color(nsColor: hudColour(for: state)),
                 ring: IconRenderer.silentRing,
                 live: live, recordedFor: recordedFor)
    }

    /// Points per pixel of the render. `hudImage` asks `ImageRenderer` for 2x, but the image it hands
    /// back is CGImage-backed and `Probe` redraws it at its own pixel size, which lands at 1 px per point
    /// in-process. Deriving it from the box is exact and survives either behaviour.
    private func scale(of rep: NSBitmapImageRep, boxHeight: CGFloat) -> Double {
        Double(rep.pixelsHigh) / Double(boxHeight)
    }

    private func pt(_ pixels: Int, _ rep: NSBitmapImageRep, _ box: CGSize) -> Double {
        Double(pixels) / scale(of: rep, boxHeight: box.height)
    }

    private var square: CGSize { HudLifecycle.fullSize(for: .loading) }
    private var wide: CGSize { HudLifecycle.fullSize(for: .recording) }

    func testTheSquareIsTheBoxTheDesignDraws() {
        guard let rep = Probe.bitmap(frame(.loading, 1, "Loading — 40%")) else { return XCTFail("no bitmap") }
        XCTAssertEqual(pt(rep.pixelsWide, rep, square), Double(square.width), accuracy: 0.5)
        XCTAssertEqual(pt(rep.pixelsHigh, rep, square), Double(square.height), accuracy: 0.5)
    }

    /// The live box is the board's wide one: 330 × 156, tall enough for a 64 pt orb and a row beneath it.
    func testTheLiveBoxIsTheBoardsWideBox() {
        guard let rep = Probe.bitmap(frame(.recording, 1, "0:07")) else { return XCTFail("no bitmap") }
        XCTAssertEqual(pt(rep.pixelsWide, rep, wide), 330, accuracy: 0.5)
        XCTAssertEqual(pt(rep.pixelsHigh, rep, wide), 156, accuracy: 0.5)
    }

    /// The complaint, as a test: the type must not be the tightest thing in the box.
    func testTheLabelsBottomClearanceIsGenerous() {
        guard let rep = Probe.bitmap(frame(.recording, 1, "0:07")) else { return XCTFail("no bitmap") }
        let groups = Probe.inkGroups(frame(.recording, 1, "0:07"))
        XCTAssertFalse(groups.isEmpty, "the frame drew no ink at all")
        guard let label = groups.last else { return }
        let belowLabel = pt(rep.pixelsHigh - label.1, rep, wide)
        XCTAssertGreaterThanOrEqual(belowLabel, 16, "the row needs room below it — measured \(belowLabel) pt")
    }

    /// The transcript's own geometry, which the wide box exists for: the newest words reach the box's right
    /// padding and stop there, and the row is one line high, not two.
    func testTheTranscriptReachesTheRightPaddingAndStops() {
        let words = "the quick brown fox jumps over the lazy dog and keeps on running through the long green field"
        let live = LiveText(words: words.split(separator: " ").map(String.init), since: 0, rate: 2.5)
        // 9 s into a 2.5 words/second take, every word has resolved.
        guard let rep = Probe.bitmap(frame(.recording, 9, "0:09", live: live)) else { return XCTFail("no bitmap") }
        let groups = Probe.inkGroups(frame(.recording, 9, "0:09", live: live))
        XCTAssertFalse(groups.isEmpty, "the transcript drew nothing")

        // Ink groups come back as (top, bottom) bands. The lowest band is the row: clock plus transcript.
        guard let row = groups.last else { return }
        let rowHeight = pt(row.1 - row.0, rep, wide)
        XCTAssertLessThan(rowHeight, 20, "one line of transcript, measured \(rowHeight) pt tall")

        // Left and right extent of that row, measured from the pixels the band's own rows carry.
        let image = frame(.recording, 9, "0:09", live: live)
        guard let span = Probe.inkColumns(image, from: row.0, to: row.1) else {
            return XCTFail("no column ink in the row")
        }
        let rightEdge = pt(span.upperBound, rep, wide)
        let rightMargin = Double(wide.width) - rightEdge
        // The box's own padding is 16 pt: the tail is pinned to it, and nothing may cross it.
        XCTAssertEqual(rightMargin, HudSpec.boxPadding, accuracy: 2.5,
                       "the transcript's tail should sit on the right padding — \(rightMargin) pt in")
    }
}
