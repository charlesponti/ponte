import AppKit
import XCTest
@testable import Ponte

/// The HUD's geometry and colour, frame by frame. These are the numbers the design board drew;
/// where a board and the code disagree, this file is the one that fails.
final class HudLifecycleTests: XCTestCase {
    private let target = CGSize(width: 200, height: 60)

    // MARK: - The clock

    /// The recording label is a live clock. It was once the design board's literal "0:07".
    func testClockCountsUpFromZero() {
        XCTAssertEqual(HudLifecycle.clock(0), "0:00")
        XCTAssertEqual(HudLifecycle.clock(4.9), "0:04")
        XCTAssertEqual(HudLifecycle.clock(59), "0:59")
        XCTAssertEqual(HudLifecycle.clock(60), "1:00")
        XCTAssertEqual(HudLifecycle.clock(65), "1:05")
        XCTAssertEqual(HudLifecycle.clock(125), "2:05")
        XCTAssertEqual(HudLifecycle.clock(600), "10:00")
    }

    func testClockNeverRunsBackwards() {
        XCTAssertEqual(HudLifecycle.clock(-5), "0:00")
    }

    // MARK: - At rest

    func testQuietStatesAreTheSquareSquircle() {
        for state in [HudState.idle, .recording, .working] {
            let g = HudLifecycle.geometry(state, 0, target: target)
            XCTAssertEqual(g.box.width, HudSpec.fullBox, "\(state)")
            XCTAssertEqual(g.box.height, HudSpec.fullBox, "\(state)")
            XCTAssertEqual(g.radius, HudSpec.fullRadius, accuracy: 0.001, "\(state)")
            XCTAssertEqual(g.visual.orb, 1, accuracy: 0.001, "\(state)")
            XCTAssertEqual(g.visual.alpha, 1, accuracy: 0.001, "\(state)")
            XCTAssertEqual(g.collapse, 0, accuracy: 0.001, "\(state)")
            XCTAssertEqual(g.hudAlpha, 1, accuracy: 0.001, "\(state)")
        }
    }

    func testRecordingSpinsAtFourTimesTheModelRate() {
        XCTAssertEqual(HudLifecycle.visual(.recording, 0).spin,
                       HudSpec.baseSpin * HudSpec.recordingSpinMultiple, accuracy: 0.0001)
        XCTAssertEqual(HudLifecycle.visual(.working, 0).spin, HudSpec.baseSpin, accuracy: 0.0001)
    }

    // MARK: - Done

    func testDoneRegistersTheColourBeforeItMoves() {
        XCTAssertEqual(HudLifecycle.geometry(.done, 0, target: target).box.width, HudSpec.fullBox,
                       "the box must not move while the colour changes")
        let green = HudLifecycle.visual(.done, HudSpec.doneHold).tint
        assertColour(green, is: HudSpec.green, "green by the end of the hold")
        let mid = HudLifecycle.visual(.done, HudSpec.doneHold / 2).tint
        XCTAssertLessThan(mid.greenComponent, HudSpec.green.greenComponent,
                          "half way through the hold the tint is between mint and green")
        XCTAssertGreaterThan(mid.greenComponent, HudSpec.mint.greenComponent)
    }

    func testDoneCollapsesTheWholeBoxToTheTextPlusPadding() {
        let end = HudSpec.doneHold + HudSpec.doneCollapse
        let g = HudLifecycle.geometry(.done, end, target: target)
        XCTAssertEqual(g.box.width, target.width, accuracy: 0.5)
        XCTAssertEqual(g.box.height, target.height, accuracy: 0.5)
        XCTAssertEqual(g.collapse, 1, accuracy: 0.001)
        XCTAssertLessThan(g.visual.orb, 0.06, "the orb has left")
        XCTAssertLessThan(g.visual.alpha, 0.02)
    }

    func testDoneShrinksMonotonically() {
        var previous = CGFloat.greatestFiniteMagnitude
        for step in 0...30 {
            let t = HudSpec.doneHold + HudSpec.doneCollapse * Double(step) / 30
            let height = HudLifecycle.geometry(.done, t, target: target).box.height
            XCTAssertLessThanOrEqual(height, previous + 0.001, "at t=\(t)")
            previous = height
        }
    }

    func testDoneHudFadesOutOverTheLastQuarterSecond() {
        XCTAssertEqual(HudLifecycle.geometry(.done, 0, target: target).hudAlpha, 1, accuracy: 0.001)
        let late = HudLifecycle.geometry(.done, HudSpec.doneLife - HudSpec.fadeOut / 2, target: target)
        XCTAssertGreaterThan(late.hudAlpha, 0.2)
        XCTAssertLessThan(late.hudAlpha, 0.8)
        XCTAssertEqual(HudLifecycle.geometry(.done, HudSpec.doneLife, target: target).hudAlpha,
                       0, accuracy: 0.001)
    }

    // MARK: - Error

    func testErrorTurnsRedBeforeItShrinks() {
        XCTAssertEqual(HudLifecycle.visual(.error, 0).tint.greenComponent,
                       HudSpec.mint.greenComponent, accuracy: 0.02)
        assertColour(HudLifecycle.visual(.error, HudSpec.errorColour).tint, is: HudSpec.red,
                     "red at the end of the colour change")
        let shrunk = HudSpec.errorColour + HudSpec.errorShrink
        XCTAssertEqual(HudLifecycle.visual(.error, shrunk).orb, 0.82, accuracy: 0.01)
    }

    /// The box holds still through the colour change, the shrink and all three throbs. Only then
    /// does it follow the orb out.
    func testErrorBoxHoldsThroughEveryThrob() {
        let moments: [TimeInterval] = [0, HudSpec.errorColour, 0.43, 0.64, 1.06, 1.27, 1.48,
                                       HudSpec.errorThrobEnd - 0.01]
        for t in moments {
            let g = HudLifecycle.geometry(.error, t, target: target)
            XCTAssertEqual(g.box.width, HudSpec.fullBox, accuracy: 0.001, "box moved at t=\(t)")
            XCTAssertEqual(g.box.height, HudSpec.fullBox, accuracy: 0.001, "box moved at t=\(t)")
            XCTAssertEqual(g.hudAlpha, 1, accuracy: 0.001, "faded early at t=\(t)")
        }
        let after = HudLifecycle.geometry(.error, HudSpec.errorThrobEnd + HudSpec.errorCollapse,
                                          target: target)
        XCTAssertEqual(after.box.width, target.width, accuracy: 0.5)
        XCTAssertEqual(after.box.height, target.height, accuracy: 0.5)
    }

    /// Three throbs, and the peaks are at throbStart + (n + 0.5) × period. A strip drawn in the app
    /// once labelled the *troughs* as peaks, which is what this test exists to prevent.
    func testErrorThrobsExactlyThreeTimesAtTheRightMoments() {
        var samples: [(t: TimeInterval, orb: CGFloat)] = []
        var t = HudSpec.errorColour
        while t <= HudSpec.errorThrobEnd {
            samples.append((t, HudLifecycle.visual(.error, t).orb))
            t += 0.002
        }
        let shrink = CGFloat(0.82)
        var peaks: [TimeInterval] = []
        for i in 1..<(samples.count - 1) {
            let before = samples[i - 1].orb, now = samples[i].orb, after = samples[i + 1].orb
            if now > before, now >= after, now > shrink + 0.05 {
                if let last = peaks.last, samples[i].t - last < HudSpec.errorThrob / 2 { continue }
                peaks.append(samples[i].t)
            }
        }
        XCTAssertEqual(peaks.count, 3, "throbs found: \(peaks)")
        let expected = (0..<3).map { HudSpec.errorColour + HudSpec.errorShrink
            + (Double($0) + 0.5) * HudSpec.errorThrob }
        for (found, want) in zip(peaks, expected) {
            XCTAssertEqual(found, want, accuracy: 0.02, "throb peak timing")
        }
        for (index, want) in expected.enumerated() {
            let orb = HudLifecycle.visual(.error, want).orb
            XCTAssertEqual(orb, shrink + CGFloat(HudSpec.errorThrobPeak), accuracy: 0.01,
                           "throb \(index + 1) amplitude")
        }
        // Troughs sit a whole period after the start of the throbs — not half a period, which is
        // where the peaks are. Asserting the wrong one is the mistake this test exists to catch.
        for trough in [HudSpec.errorThrobEnd - HudSpec.errorThrob,
                       HudSpec.errorThrobEnd - HudSpec.errorThrob * 2] {
            XCTAssertEqual(HudLifecycle.visual(.error, trough).orb, shrink, accuracy: 0.02,
                           "trough at \(trough)")
        }
    }

    // MARK: - Lifetimes

    func testOnlyFinishedStatesHideThemselves() {
        XCTAssertEqual(HudLifecycle.lifetime(.done), HudSpec.doneLife)
        XCTAssertEqual(HudLifecycle.lifetime(.error), HudSpec.errorLife)
        for state in [HudState.idle, .recording, .working] {
            XCTAssertNil(HudLifecycle.lifetime(state))
        }
        XCTAssertGreaterThan(HudSpec.errorLife, HudSpec.doneLife,
                             "an error is worth reading for longer than a success")
    }

    // MARK: - The pill

    func testPillIsTheMeasuredTextPlusSixteenOnEverySide() {
        let font = NSFont.systemFont(ofSize: HudSpec.finalLabelSize, weight: .semibold)
        for text in ["Pasted ✓", "Heard nothing", "Microphone access denied — System Settings"] {
            let measured = (text as NSString).size(withAttributes: [.font: font])
            let pill = HudLifecycle.pillSize(for: text)
            XCTAssertEqual(pill.width, ceil(measured.width) + HudSpec.boxPadding * 2, accuracy: 0.01)
            XCTAssertEqual(pill.height, ceil(measured.height) + HudSpec.boxPadding * 2, accuracy: 0.01)
        }
    }

    func testALongerPillIsWider() {
        let short = HudLifecycle.pillSize(for: "Pasted ✓")
        let long = HudLifecycle.pillSize(for: "Microphone access denied — System Settings ▸ Privacy")
        XCTAssertGreaterThan(long.width, short.width)
        XCTAssertEqual(short.height, long.height, accuracy: 0.01, "one line stays one line")
    }

    // MARK: - The voice

    /// The orb and the level it shows come from the Waveform package; what Ponte owns is the numbers
    /// it feeds that view. The gain is the one that has to hold: at 0.45 (Waveform's own) the dots
    /// reach into the label in a 96 px box.
    func testTheOrbIsSizedForItsBox() {
        XCTAssertEqual(HudSpec.orbGain, 0.25, accuracy: 0.0001)
        XCTAssertEqual(HudSpec.orbSize, 64)
        XCTAssertEqual(HudSpec.voiceFloor, -55, "the floor that counts as silence")
        XCTAssertEqual(HudSpec.columnsPerSecond, 120, "how fast the engine's columns arrive")
    }
}
