import AppKit
import simd
import XCTest
@testable import Ponte

/// The sphere itself: where its dots sit, how big they are, and — the part that once went wrong —
/// how loudness moves them.
final class OrbTests: XCTestCase {

    // MARK: - The lattice

    func testDotsSitOnTheSphereAndKnowTheirAge() {
        let lattice = OrbLattice(count: 500)
        XCTAssertEqual(lattice.count, 500)
        XCTAssertEqual(lattice.unit.count, 500)
        for (index, dot) in lattice.unit.enumerated() {
            XCTAssertEqual(simd_length(dot), 1, accuracy: 0.001, "dot \(index) is off the sphere")
        }
        XCTAssertEqual(lattice.age.min() ?? 1, 0, accuracy: 0.02, "the equator is the newest sound")
        // The outermost dot sits one step in from the pole, so it is close to 1 but never 1.
        XCTAssertGreaterThanOrEqual(lattice.age.max() ?? 0, 0.95, "the poles are the oldest")
        XCTAssertLessThan(lattice.age.min() ?? 1, 0.05, "the equator is the newest")
    }

    func testTheDefaultLatticeIsTheOneTheHudDraws() {
        XCTAssertEqual(OrbRenderer.lattice.count, 1100)
        XCTAssertEqual(OrbRenderer.fullSize, 64)
    }

    func testRowsMakeARingPerRow() {
        let lattice = OrbLattice.rows(rings: 8) { row in 4 + row }
        XCTAssertEqual(lattice.count, (0...8).map { 4 + $0 }.reduce(0, +))
        XCTAssertEqual(lattice.age.min() ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(lattice.age.max() ?? 0, 1, accuracy: 0.001)
    }

    // MARK: - The projection

    func testDepthAndLayersCoverTheirRange() {
        var depths: [Float] = []
        for dot in OrbRenderer.lattice.unit {
            depths.append(OrbProjection.place(dot, out: 1, spin: 1.1).depth)
        }
        XCTAssertGreaterThanOrEqual(depths.min() ?? -1, 0)
        XCTAssertLessThanOrEqual(depths.max() ?? 2, 1)
        XCTAssertEqual(OrbProjection.layer(depth: 0), 0)
        XCTAssertEqual(OrbProjection.layer(depth: 1), 3)
        XCTAssertEqual(OrbProjection.layer(depth: 0.5), 2)
    }

    func testNearerDotsAreLarger() {
        XCTAssertLessThan(OrbProjection.perspective(depth: 0), OrbProjection.perspective(depth: 1))
        XCTAssertEqual(OrbProjection.perspective(depth: 0), 0.75, accuracy: 0.0001)
        XCTAssertEqual(OrbProjection.perspective(depth: 1), 1.0, accuracy: 0.0001)
    }

    /// Full voice has to land on the orb the design board draws, inside the box it shares with a
    /// label. That pins the gain, which is smaller than the sibling app's 0.45 on purpose.
    func testTheRadiusLeavesRoomForFullVoice() {
        XCTAssertEqual(OrbProjection.gain, 0.25, accuracy: 0.0001)
        XCTAssertEqual(OrbProjection.radius(in: 64), 24.06, accuracy: 0.05)
        // at full voice the dots reach the sphere's full size
        let full = OrbProjection.radius(in: 64) * (1 + OrbProjection.gain)
        XCTAssertEqual(full, 30.08, accuracy: 0.1, "half of the 60 px orb the board shows")
        XCTAssertEqual(OrbProjection.radius(in: 128), OrbProjection.radius(in: 64) * 2, accuracy: 0.01)
    }

    // MARK: - Loudness moves the dots (the bug this file exists for)

    /// The orb drawn at twice its nominal size, so a dot is a few pixels across and the bounds are
    /// measurable. Divide by two for the size the HUD would show.
    private func inkAt(level: Float, peak: Float? = nil, size: CGFloat = 64, spin: Float = 1.1) -> Ink {
        Probe.mint(Probe.image(pixels: Int(size * 2)) { ctx in
            ctx.scaleBy(x: 2, y: 2)
            OrbRenderer.draw(in: ctx, center: CGPoint(x: size / 2, y: size / 2), size: size,
                             tint: HudSpec.mint, alpha: 1, spin: spin,
                             voice: { _ in (level, peak ?? level) })
        })
    }

    /// The renderer once treated the *level* as the radius multiplier, so the orb collapsed toward
    /// a point as the user spoke. Louder must mean bigger, at every step.
    func testLouderAlwaysMeansBigger() {
        var widths: [CGFloat] = []
        for level in stride(from: Float(0), through: 1, by: 0.25) {
            widths.append(inkAt(level: level).bounds.width)
        }
        for (index, width) in widths.enumerated().dropFirst() {
            XCTAssertGreaterThan(width, widths[index - 1],
                                 "level \(Double(index) * 0.25) did not grow the orb: \(widths)")
        }
    }

    func testSilenceIsAPlainSphere() {
        let silent = inkAt(level: 0)
        XCTAssertGreaterThan(silent.count, 0, "a quiet room still draws a sphere")
        // silence and "no voice at all" are the same picture
        let plain = Probe.mint(Probe.image(pixels: 128) { ctx in
            ctx.scaleBy(x: 2, y: 2)
            OrbRenderer.draw(in: ctx, center: CGPoint(x: 32, y: 32), size: 64,
                             tint: HudSpec.mint, alpha: 1, spin: 1.1)
        })
        XCTAssertEqual(plain.bounds.width, silent.bounds.width, accuracy: 3)
    }

    func testFullVoiceFillsTheOrbsNominalSize() {
        // peak 0 so only the level moves the dots; a peak also thickens them, which the next test
        // covers, and mixing the two here would hide a change in either.
        let silent = inkAt(level: 0, peak: 0).bounds.width
        let loud = inkAt(level: 1, peak: 0).bounds.width
        XCTAssertEqual(silent, 96, accuracy: 6, "the resting sphere is 48 px across, 96 at 2x")
        XCTAssertEqual(loud, 122, accuracy: 6, "full voice is the 60 px orb, 120 at 2x")
        XCTAssertEqual(loud / silent, 1.27, accuracy: 0.05, "the gain of 0.25, made visible")
    }

    func testAPeakThickensTheDotsWithoutMovingThem() {
        let flat = inkAt(level: 0.5, peak: 0)
        let peaked = inkAt(level: 0.5, peak: 1)
        XCTAssertGreaterThan(peaked.count, Int(Double(flat.count) * 1.5),
                             "a high peak draws fatter dots")
        // The dots' centres do not move; the bounding box grows by the extra dot radius.
        XCTAssertEqual(peaked.bounds.width, flat.bounds.width, accuracy: 8,
                       "the peak must not move the dots, only thicken them")
        XCTAssertGreaterThan(peaked.peak, 0.5)
    }

    func testNothingIsDrawnWhenInvisible() {
        let image = Probe.image(pixels: 128) { ctx in
            OrbRenderer.draw(in: ctx, center: CGPoint(x: 64, y: 64), size: 64,
                             tint: HudSpec.mint, alpha: 0, spin: 0)
        }
        XCTAssertEqual(Probe.mint(image).count, 0)
    }

    func testTurningChangesThePictureButNotItsSize() {
        let a = inkAt(level: 0, spin: 0), b = inkAt(level: 0, spin: 1.1)
        XCTAssertEqual(a.bounds.width, b.bounds.width, accuracy: 2)
        XCTAssertNotEqual(a.count, b.count, "a turned sphere is a different picture")
    }
}
