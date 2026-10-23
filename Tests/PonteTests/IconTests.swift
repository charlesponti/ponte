import AppKit
import XCTest
@testable import Ponte

/// The app icon: exact sizes, a face that reaches the corners properly, and — the part that needed
/// work — staying readable when the tile is tiny. The mark itself is `WaveformUI`'s orb, drawn by the
/// same view the HUD uses, so these tests are about how it is used at each size.
@MainActor
final class IconTests: XCTestCase {

    func testEveryMarkDraws() {
        XCTAssertEqual(IconMark.allCases.count, 4)
        for mark in IconMark.allCases {
            let ink = Probe.mint(IconRenderer.image(mark, size: 512))
            XCTAssertGreaterThan(ink.count, 5_000, "\(mark) drew almost nothing")
            XCTAssertGreaterThan(ink.peak, 0.7, "\(mark) is too dim")
        }
    }

    /// An icon has to be the size it was asked for: macOS picks these per slot.
    func testEverySizeIsExactlyThatManyPixels() {
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            for mark in IconMark.allCases {
                let image = IconRenderer.image(mark, size: CGFloat(size))
                // ImageRenderer hands back a CGImage-backed image, so ask the probe to read it.
                let rep = Probe.bitmap(image)
                XCTAssertEqual(rep?.pixelsWide, size, "\(mark) at \(size)")
                XCTAssertEqual(rep?.pixelsHigh, size, "\(mark) at \(size)")
            }
        }
    }

    /// A dotted sphere smears into a grey disc as the tile shrinks. The renderer answers by growing
    /// the dots relative to the sphere, so the small sizes get *denser*, not dimmer.
    func testTheMarkStaysReadableAtSixteenPixels() {
        for mark in IconMark.allCases {
            let tiny = Probe.mint(IconRenderer.image(mark, size: 16))
            XCTAssertGreaterThan(tiny.peak, 0.7, "\(mark) at 16 px is a smudge: peak \(tiny.peak)")
            XCTAssertGreaterThan(tiny.coverage, 0.10, "\(mark) at 16 px barely covers its tile")
            let big = Probe.mint(IconRenderer.image(mark, size: 512))
            XCTAssertGreaterThan(tiny.coverage, big.coverage,
                                 "\(mark): the dot hint should make small tiles denser, not sparser")
        }
    }

    /// The dots are an absolute point size in `WaveformUI`, so the multiplier must fall as the tile
    /// does — but *slower* than proportionally, which is the nudge that keeps a 16 px tile filled.
    func testTheDotHintAnswersTheTileSize() {
        XCTAssertLessThan(IconRenderer.dotScale(forTile: 16), IconRenderer.dotScale(forTile: 512))
        XCTAssertLessThan(IconRenderer.dotScale(forTile: 512), IconRenderer.dotScale(forTile: 1024))
        let perPoint = { (size: CGFloat) in IconRenderer.dotScale(forTile: size) / Double(size) }
        XCTAssertGreaterThan(perPoint(16), perPoint(512), "small tiles get relatively bigger dots")
        XCTAssertGreaterThan(perPoint(512), perPoint(1024), "and so do medium ones")
    }

    func testTheFaceIsOpaqueInsideAndClearAtTheCorners() {
        let image = IconRenderer.image(.orb, size: 512)
        let corner = Probe.alpha(image, atX: 2, y: 2)
        XCTAssertLessThan(corner, 0.05, "the squircle's corner should be transparent")
        // just inside the body, at the vertical middle
        let middle = Probe.alpha(image, atX: 96, y: 256)
        XCTAssertGreaterThan(middle, 0.9, "the face should be opaque")
        // the face and the HUD's box are both near-black, even if not the same value
        let face = srgb(IconRenderer.face), box = srgb(HudSpec.boxFill)
        XCTAssertLessThan(face.r + face.g + face.b, 0.15, "the icon's face is near-black")
        XCTAssertLessThan(box.r + box.g + box.b, 0.15, "the HUD's box is near-black")
    }

    /// The menu bar glyph is a silhouette — a core and a ring — because at 18 pt the dot sphere
    /// merges into a fuzzy disc with no readable outline.
    func testTheMenuBarMarkIsATemplateWithACoreAndARing() {
        let image = IconRenderer.menuBarImage(pointSize: 18)
        XCTAssertTrue(image.isTemplate, "a menu bar mark must be templated for light and dark bars")
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        XCTAssertEqual(rep?.pixelsWide, 36, "18 pt at 2x")

        let ink = Probe.anyInk(image)
        XCTAssertGreaterThan(ink.count, 50, "the mark drew nothing")
        // centred, and roughly as wide as it is tall
        XCTAssertEqual(ink.bounds.midX, 18, accuracy: 1.5)
        XCTAssertEqual(ink.bounds.midY, 18, accuracy: 1.5)
        XCTAssertEqual(ink.bounds.width, ink.bounds.height, accuracy: 2)

        // The core is solid and there is a gap before the ring. Probe in *pixels*: the image is
        // 36 px wide for an 18 pt mark, and probing in points is how the mark ended up misdrawn.
        let side = 36.0
        XCTAssertGreaterThan(Probe.alpha(image, atX: 18, y: 18), 0.9, "solid core")
        XCTAssertGreaterThan(Probe.alpha(image, atX: 18 - Int(side * 0.14), y: 18), 0.9,
                             "inside the core")
        XCTAssertLessThan(Probe.alpha(image, atX: Int(side * 0.30), y: 18), 0.15,
                          "the gap between core and ring")
        XCTAssertGreaterThan(Probe.alpha(image, atX: Int(side * 0.42), y: 18), 0.5,
                             "the ring itself")
        // the mark is a glyph with air around it, unlike the app icon, which fills its tile
        XCTAssertLessThan(Probe.alpha(image, atX: 1, y: 1), 0.05, "the corner is clear")
    }

    /// Big and small are drawn to look different on purpose: at 512 px the sphere is shaded by
    /// depth (dim far dots behind bright near ones), while at 16 px it is a dense disc. Flat
    /// brightness at 512 would mean the depth layers had stopped being drawn.
    func testTheBigIconIsShadedByDepthAndTheTinyOneIsDense() {
        let big = Probe.mint(IconRenderer.image(.orb, size: 512))
        XCTAssertGreaterThan(big.peak, 0.7, "the nearest dots are bright")
        XCTAssertLessThan(big.p10, 0.45, "the farthest dots are dim — that is the depth cue")
        let tiny = Probe.mint(IconRenderer.image(.orb, size: 16))
        XCTAssertGreaterThan(tiny.brightShare, big.brightShare * 2,
                             "at 16 px the mark should read as one flat, even disc — full-strength ink is \(Int(tiny.brightShare * 100))% of it against \(Int(big.brightShare * 100))% of the shaded sphere")
    }

    /// Every mark has to be centred in its tile: the menu bar glyph was once drawn in the
    /// bottom-left quadrant because a pixel context was measured in points.
    func testEveryMarkIsCentredInItsTile() {
        for mark in IconMark.allCases {
            for size in [32, 256] {
                let image = IconRenderer.image(mark, size: CGFloat(size))
                let ink = Probe.mint(image)
                XCTAssertEqual(ink.bounds.midX, CGFloat(size) / 2, accuracy: CGFloat(size) * 0.06,
                               "\(mark) at \(size) is off-centre horizontally")
                XCTAssertEqual(ink.bounds.midY, CGFloat(size) / 2, accuracy: CGFloat(size) * 0.06,
                               "\(mark) at \(size) is off-centre vertically")
            }
        }
    }
}
