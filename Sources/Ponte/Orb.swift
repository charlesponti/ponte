import AppKit

// MARK: - The lifecycle
//
// The sphere itself — its lattice, its projection, the dots and the sound they show — now comes from
// the Waveform package (`WaveformCore` for the maths, `WaveformUI` for the drawing), shared with
// Thames. What is left here is only what is Ponte's own: when the box moves, how a pulse feels, how
// the pill is measured, and the clock.

enum HudState: String {
    case idle, recording, working, done, error, cancelled
}

/// Every colour and duration of the lifecycle, in one place. These are the numbers from
/// design/hud-b-lifecycle-v2.html — the board is the spec.
enum HudSpec {
    // tints, exactly as the board draws them
    static let mint = NSColor(srgbRed: 102 / 255, green: 212 / 255, blue: 207 / 255, alpha: 1)
    static let green = NSColor(srgbRed: 50 / 255, green: 215 / 255, blue: 75 / 255, alpha: 1)
    static let red = NSColor(srgbRed: 255 / 255, green: 69 / 255, blue: 58 / 255, alpha: 1)
    /// The input watcher's colour: a warning rather than a failure — the recording carries on.
    static let amber = NSColor(srgbRed: 255 / 255, green: 214 / 255, blue: 10 / 255, alpha: 1)
    /// Cancelled is neither of those: it drains to grey, because nothing succeeded and nothing failed.
    static let grey = NSColor(srgbRed: 142 / 255, green: 142 / 255, blue: 147 / 255, alpha: 1)

    // What the box is made of. Black, not the usual translucent `.hudWindow` material: the orb's
    // outer dots are drawn at 18 % and vanish against a grey blur. The face and the hairline are here
    // so the app and the offscreen renders cannot drift apart.
    static let boxFill = NSColor.black
    static let boxFillAlpha: CGFloat = 0.94
    static let boxBorderAlpha: CGFloat = 0.12

    static let baseSpin: Float = 0.35                // rad/s, the model's own rate
    static let recordingSpinMultiple: Float = 4      // "spins fast" while recording
    static let workingSpin: Float = 0.35             // calm

    static let fullBox: CGFloat = 96                 // the squircle
    static let fullRadius: CGFloat = 26
    static let finalRadius: CGFloat = 18
    static let boxPadding: CGFloat = 16              // 16 px top, bottom, left, right
    static let finalLabelSize: CGFloat = 12.5
    static let smallLabelSize: CGFloat = 10

    // done: hold the colour, then collapse
    static let doneHold: TimeInterval = 0.15
    static let doneCollapse: TimeInterval = 0.55
    static let doneLife: TimeInterval = 1.40

    // cancelled: the collapse of done without the ceremony — grey, and gone in a second
    static let cancelHold: TimeInterval = 0.10
    static let cancelCollapse: TimeInterval = 0.42
    static let cancelLife: TimeInterval = 1.10

    // error: colour, shrink, three throbs, then collapse
    static let errorColour: TimeInterval = 0.18
    static let errorShrink: TimeInterval = 0.25
    static let errorThrob: TimeInterval = 0.42
    static let errorThrobCount = 3
    static let errorThrobPeak = 0.12
    static let errorCollapse: TimeInterval = 0.46
    static let errorLife: TimeInterval = 3.00

    static var errorThrobEnd: TimeInterval {
        errorColour + errorShrink + Double(errorThrobCount) * errorThrob
    }

    // fade the whole HUD out over the last quarter second of its life
    static let fadeOut: TimeInterval = 0.25

    // MARK: - The voice

    /// The orb's nominal size, and how far full scale pushes a dot out.
    ///
    /// Waveform's own orb uses a gain of 0.45 in a canvas of its own. Here the orb shares a fixed
    /// 96 px box with a label, and at 0.45 the dots reach into it: at 0.25 the loudest voice lands on
    /// exactly the 60 px orb the design board draws, and a quiet room is a smaller, calmer sphere.
    static let orbSize: CGFloat = 64
    static let orbGain: Float = 0.25
    static let orbDots = 1100

    /// `WaveformUI` draws dots at an absolute point size, tuned for an orb of a few hundred points.
    /// At 64 px the same dots would cover the sphere twice over, so a small orb passes a smaller
    /// multiplier and looks like a dotted sphere rather than a solid one.
    static let orbDotScale: Double = 0.28

    /// How much of the past the orb spans, equator to pole, and what counts as silence.
    static let voiceHistory: Double = 0.8
    /// dBFS drawn as nothing: the engine's columns are mapped onto the display range by this.
    static let voiceFloor: Float = -55
    /// Columns a second the engine produces, so the orb's playhead knows how fast time runs.
    static let columnsPerSecond: Double = 120
}

struct HudVisual {
    var tint: NSColor
    var spin: Float
    var orb: CGFloat        // orb scale, 0...1 of its nominal size
    var alpha: CGFloat      // orb alpha
}

struct HudGeometry {
    var box: CGSize
    var radius: CGFloat
    var orbPx: CGFloat
    var labelSize: CGFloat
    var gap: CGFloat
    var hudAlpha: CGFloat
    var collapse: CGFloat   // 0 at rest, 1 fully collapsed
    var visual: HudVisual
}

enum HudLifecycle {
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
    static func ease(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
    static func mix(_ a: NSColor, _ b: NSColor, _ t: Double) -> NSColor {
        let f = clamp(t, 0, 1)
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * f,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f,
                       alpha: 1)
    }

    static func visual(_ state: HudState, _ t: TimeInterval) -> HudVisual {
        switch state {
        case .idle:
            return HudVisual(tint: HudSpec.mint, spin: HudSpec.baseSpin, orb: 1, alpha: 1)
        case .recording:
            return HudVisual(tint: HudSpec.mint,
                             spin: HudSpec.baseSpin * HudSpec.recordingSpinMultiple, orb: 1, alpha: 1)
        case .working:
            return HudVisual(tint: HudSpec.mint, spin: HudSpec.workingSpin, orb: 1, alpha: 1)
        case .done:
            let k = clamp((t - HudSpec.doneHold) / HudSpec.doneCollapse, 0, 1)
            return HudVisual(tint: mix(HudSpec.mint, HudSpec.green, t / HudSpec.doneHold),
                             spin: HudSpec.baseSpin * HudSpec.recordingSpinMultiple * Float(1 - 0.85 * k),
                             orb: 1 - 0.95 * CGFloat(ease(k)),
                             alpha: 1 - CGFloat(ease(k)))
        case .cancelled:
            let k = clamp((t - HudSpec.cancelHold) / HudSpec.cancelCollapse, 0, 1)
            return HudVisual(tint: mix(HudSpec.mint, HudSpec.grey, t / HudSpec.cancelHold),
                             spin: HudSpec.baseSpin * HudSpec.recordingSpinMultiple * Float(1 - 0.85 * k),
                             orb: 1 - 0.95 * CGFloat(ease(k)),
                             alpha: 1 - CGFloat(ease(k)))
        case .error:
            let shrinkK = clamp((t - HudSpec.errorColour) / HudSpec.errorShrink, 0, 1)
            let shrink = 1 - 0.18 * ease(shrinkK)
            let throbStart = HudSpec.errorColour + HudSpec.errorShrink
            let tk = (t - throbStart) / HudSpec.errorThrob
            var orb = shrink
            if tk > 0 && tk < Double(HudSpec.errorThrobCount) {
                orb += HudSpec.errorThrobPeak * abs(sin(tk * .pi))
            }
            let exitK = clamp((t - HudSpec.errorThrobEnd) / HudSpec.errorCollapse, 0, 1)
            orb *= (1 - 0.95 * ease(exitK))
            return HudVisual(tint: mix(HudSpec.mint, HudSpec.red, t / HudSpec.errorColour),
                             spin: HudSpec.baseSpin * HudSpec.recordingSpinMultiple * Float(1 - 0.65 * shrinkK),
                             orb: CGFloat(orb),
                             alpha: 1 - CGFloat(ease(exitK)))
        }
    }

    /// The text the HUD ends up showing, measured at the final label size, plus 16 px all round.
    static func pillSize(for text: String) -> CGSize {
        let font = NSFont.systemFont(ofSize: HudSpec.finalLabelSize, weight: .semibold)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(measured.width) + HudSpec.boxPadding * 2,
                      height: ceil(measured.height) + HudSpec.boxPadding * 2)
    }

    static func geometry(_ state: HudState, _ t: TimeInterval, target: CGSize) -> HudGeometry {
        let v = visual(state, t)
        var k = 0.0
        var hudAlpha = 1.0
        switch state {
        case .done:
            k = clamp((t - HudSpec.doneHold) / HudSpec.doneCollapse, 0, 1)
            hudAlpha = 1 - clamp((t - (HudSpec.doneLife - HudSpec.fadeOut)) / HudSpec.fadeOut, 0, 1)
        case .cancelled:
            k = clamp((t - HudSpec.cancelHold) / HudSpec.cancelCollapse, 0, 1)
            hudAlpha = 1 - clamp((t - (HudSpec.cancelLife - HudSpec.fadeOut)) / HudSpec.fadeOut, 0, 1)
        case .error:
            k = clamp((t - HudSpec.errorThrobEnd) / HudSpec.errorCollapse, 0, 1)
            hudAlpha = 1 - clamp((t - (HudSpec.errorLife - HudSpec.fadeOut)) / HudSpec.fadeOut, 0, 1)
        default:
            break
        }
        let e = ease(k)
        let w = HudSpec.fullBox + (target.width - HudSpec.fullBox) * e
        let h = HudSpec.fullBox + (target.height - HudSpec.fullBox) * e
        return HudGeometry(
            box: CGSize(width: w, height: h),
            radius: min(h / 2, HudSpec.fullRadius + (HudSpec.finalRadius - HudSpec.fullRadius) * e),
            orbPx: HudSpec.orbSize * v.orb,
            labelSize: HudSpec.smallLabelSize + (HudSpec.finalLabelSize - HudSpec.smallLabelSize) * e,
            gap: 5 + (0 - 5) * e,
            hudAlpha: hudAlpha,
            collapse: e,
            visual: v)
    }

    /// When a finished state should hide itself.
    static func lifetime(_ state: HudState) -> TimeInterval? {
        switch state {
        case .done: return HudSpec.doneLife
        case .error: return HudSpec.errorLife
        case .cancelled: return HudSpec.cancelLife
        default: return nil
        }
    }

    /// The recording clock: counts up from nothing, m:ss.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
