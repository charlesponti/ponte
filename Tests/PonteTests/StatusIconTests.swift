import AppKit
import XCTest
@testable import Ponte

/// What the menu bar is handed in each state. The failures these guard against are quiet ones: an
/// image that is not a template is drawn as-is, so a black glyph vanishes on a dark bar, and a mark
/// drawn in pixel coordinates inside a point-sized canvas lands off centre at half size — which looks
/// perfectly fine in the source.
@MainActor
final class StatusIconTests: XCTestCase {

    func testEveryStateHandsTheBarATemplateImage() {
        for state in AppState.allCases {
            let image = StatusIcon.image(for: state)
            XCTAssertTrue(image.isTemplate, "\(state) is not a template, so a tint cannot be applied")
            XCTAssertGreaterThan(image.size.width, 8, "\(state) is too small for the bar")
            XCTAssertGreaterThan(image.size.height, 8, "\(state) is too small for the bar")
        }
    }

    func testOnlyTheRestingStateWearsTheAppsOwnMark() {
        XCTAssertNil(StatusIcon.symbol(for: .idle), "the bar should wear our mark when idle")
        XCTAssertNil(StatusIcon.tint(for: .idle), "and let the system tint it for the bar it is on")
        for state in [AppState.starting, .recording, .working] {
            XCTAssertNotNil(StatusIcon.symbol(for: state), "\(state) should use a system glyph")
            XCTAssertNotNil(StatusIcon.tint(for: state), "\(state) should be coloured")
        }
        XCTAssertEqual(StatusIcon.tint(for: .recording), .systemRed)
        XCTAssertEqual(StatusIcon.tint(for: .working), .systemOrange)
    }

    /// Every mark has to sit in the middle of its canvas.
    func testEveryMarkIsCentredInItsCanvas() {
        for mark in MenuBarMark.allCases {
            let image = IconRenderer.menuBarImage(mark, pointSize: 18)
            guard let rep = Probe.bitmap(image) else {
                XCTFail("\(mark) has no bitmap"); continue
            }
            let ink = Probe.anyInk(image)
            XCTAssertEqual(ink.bounds.midX, CGFloat(rep.pixelsWide) / 2, accuracy: 2,
                           "\(mark) is off centre horizontally")
            XCTAssertEqual(ink.bounds.midY, CGFloat(rep.pixelsHigh) / 2, accuracy: 2,
                           "\(mark) is off centre vertically")
        }
    }

    /// The resting mark has to be the same optical size as the system glyphs, or the menu bar item
    /// visibly grows and shrinks every time you record.
    func testTheRestingMarkMatchesTheSizeOfTheSystemGlyphs() {
        let mark = StatusIcon.image(for: .idle)
        let glyph = StatusIcon.image(for: .recording)
        XCTAssertEqual(mark.size.width, glyph.size.width, accuracy: 2)
        XCTAssertEqual(mark.size.height, glyph.size.height, accuracy: 2)
    }
}
