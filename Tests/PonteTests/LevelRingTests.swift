import XCTest
@testable import Ponte

/// The voice history the orb reads: one entry per meter tick, sampled at any fractional age.
final class LevelRingTests: XCTestCase {

    func testAnEmptyRingIsSilent() {
        let ring = LevelRing()
        let (level, peak) = ring.sample(at: 0)
        XCTAssertEqual(level, 0)
        XCTAssertEqual(peak, 0)
        XCTAssertEqual(ring.head, 0)
    }

    func testItRemembersWhatWasHeard() {
        let ring = LevelRing()
        ring.append(level: 0.4, peak: 0.9)
        XCTAssertEqual(ring.head, 1)
        XCTAssertEqual(ring.sample(at: 0).level, 0.4, accuracy: 0.0001)
        XCTAssertEqual(ring.sample(at: 0).peak, 0.9, accuracy: 0.0001)
    }

    /// Before the recording started there was no sound, and the orb must not invent any.
    func testBeforeTheStartIsSilence() {
        let ring = LevelRing()
        for _ in 0..<5 { ring.append(level: 0.8, peak: 0.8) }
        XCTAssertEqual(ring.sample(at: -1).level, 0, accuracy: 0.0001)
        XCTAssertEqual(ring.sample(at: -20).level, 0, accuracy: 0.0001)
    }

    /// Catmull-Rom runs through the points: at a whole position it is that entry.
    func testTheCurvePassesThroughItsPoints() {
        let ring = LevelRing()
        for value in [Float(0.1), 0.6, 0.2, 0.9] { ring.append(level: value, peak: 0) }
        for (index, value) in [Float(0.1), 0.6, 0.2, 0.9].enumerated() {
            XCTAssertEqual(ring.sample(at: Double(index)).level, value, accuracy: 0.0001)
        }
    }

    /// Inside the buffer a constant reads as itself. At the very edges the curve leans on the
    /// silence before the recording began, which is what stops a fade-in from jumping.
    func testAConstantLevelInterpolatesToItself() {
        let ring = LevelRing()
        for _ in 0..<10 { ring.append(level: 0.55, peak: 0.2) }
        for position in stride(from: 2.0, through: 7.0, by: 0.13) {
            XCTAssertEqual(ring.sample(at: position).level, 0.55, accuracy: 0.01,
                           "at \(position)")
        }
    }

    /// Smoothness is the point of the curve: no corners as the playhead moves between entries.
    func testTheCurveHasNoCorners() {
        let ring = LevelRing()
        for value in [Float(0), 0, 1, 1, 0, 0, 0.5, 0.5] { ring.append(level: value, peak: 0) }
        var previous = ring.sample(at: 0).level
        for step in 1...400 {
            let level = ring.sample(at: Double(step) / 50).level
            XCTAssertLessThan(abs(level - previous), 0.06, "jump at \(Double(step) / 50)")
            previous = level
        }
    }

    func testLevelsStayWithinTheirRange() {
        let ring = LevelRing()
        // a hard step makes Catmull-Rom overshoot if it is not clamped
        for value in [Float(0), 0, 0, 0, 1, 1, 1] { ring.append(level: value, peak: value) }
        for step in 0...400 {
            let (level, peak) = ring.sample(at: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(level, 0)
            XCTAssertLessThanOrEqual(peak, 1)
        }
    }

    func testResetForgetsEverything() {
        let ring = LevelRing()
        for _ in 0..<3 { ring.append(level: 0.9, peak: 0.9) }
        ring.reset()
        XCTAssertEqual(ring.head, 0)
        XCTAssertEqual(ring.sample(at: 0).level, 0)
    }

    /// A long recording must not read recycled entries as if they were recent.
    func testItSurvivesMoreTicksThanItCanHold() {
        let ring = LevelRing(capacity: 16)
        for index in 0..<200 { ring.append(level: Float(index % 10) / 10, peak: 0) }
        XCTAssertEqual(ring.head, 200)
        XCTAssertEqual(ring.sample(at: 199).level, Float(9) / 10, accuracy: 0.0001)
        XCTAssertEqual(ring.sample(at: 190).level, Float(0) / 10, accuracy: 0.0001)
        // far enough back that the slot has been overwritten: silence rather than a wrong value
        XCTAssertEqual(ring.sample(at: 0).level, 0, accuracy: 0.0001)
    }

    func testTheBasisPropertiesOfTheCurve() {
        // p1 at t = 0, p2 at t = 1
        XCTAssertEqual(LevelRing.catmullRom(0.2, 0.7, 0.4, 0.9, 0), 0.7, accuracy: 0.0001)
        XCTAssertEqual(LevelRing.catmullRom(0.2, 0.7, 0.4, 0.9, 1), 0.4, accuracy: 0.0001)
    }
}
