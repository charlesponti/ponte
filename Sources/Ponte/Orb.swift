import AppKit

// MARK: - The lifecycle
//
// The sphere itself — its lattice, its projection, the dots and the sound they show — now comes from
// the Waveform package (`WaveformCore` for the maths, `WaveformUI` for the drawing), shared with
// Thames. What is left here is only what is Ponte's own: when the box moves, how a pulse feels, how
// the pill is measured, and the clock.

enum HudState: String {
    case idle, recording, working, done, error, cancelled, loading
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
    /// The loading state's text: blue-grey, so a wait reads as neither a warning nor a success.
    static let blueGrey = NSColor(srgbRed: 139 / 255, green: 154 / 255, blue: 168 / 255, alpha: 1)
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
    /// Loading: grey, and the calm rate, so the wait reads as a clock — steady and unhurried.
    ///
    /// Which way `spin` actually turns the surface is not obvious from the name, so: `OrbProjection`
    /// places a dot at `x1 = u.x·cos + u.z·sin`, so a dot on the front equator (u = (0, 0, 1)) lands at
    /// `sin(spin)`. A positive rate therefore carries the visible surface to the right — the direction a
    /// clock's hand travels across the top of its dial — and that is the way this turns. It is also the
    /// way the app already turned, so what changes here is the grey and the steadiness, not the sense of
    /// the rotation. (The sphere spins about its vertical axis like a globe, so there is no in-plane
    /// rotation to reverse; a whole-sphere rotation in the screen plane would be a different motion.)
    static let loadingSpinDefault: Float = 0.9
    /// Tunable by eye, because the right speed is a matter of looking at it:
    /// `defaults write com.ponti.ponte hudLoadingSpin -float 1.2` then start a dictation.
    ///
    /// Why 0.9: the dots are a golden spiral, deliberately free of features, so a still pair of frames
    /// differs by the same amount at *any* rate — the metric cannot rank speeds, only the eye can. 0.35
    /// (the resting rate) reads as a faint shimmer rather than a turn, and 1.4 is what the app uses to
    /// say "spins fast" while recording. This sits between: plainly turning, and unhurried.
    static var loadingSpin: Float {
        let key = "hudLoadingSpin"
        return UserDefaults.standard.object(forKey: key) == nil
            ? loadingSpinDefault
            : Float(UserDefaults.standard.double(forKey: key))
    }

    /// The squircle while recording or working. Sized from its contents — a 64 pt orb, a 5 pt gap and a
    /// 12.5 pt label frame — plus enough room that the *visible* text is not crowded at the bottom.
    ///
    /// It used to be 96, which left the text ink 10 pt above the bottom edge against 15 pt above the
    /// orb: the block was centred as frames, and a label's frame carries descender space the glyphs do
    /// not use, so the type looked like it was falling out of the box. At 104 with the block lifted 4,
    /// the orb does not move (15 pt above it, as before) and the text gets 18 pt below it.
    static let fullBox: CGFloat = 104
    /// Lifts the orb-and-label block inside the square. Tunable without a rebuild:
    /// `defaults write com.ponti.ponte hudBlockLift -float 8` then relaunch.
    static var blockLift: CGFloat {
        let key = "hudBlockLift"
        return UserDefaults.standard.object(forKey: key) == nil ? 4 : CGFloat(UserDefaults.standard.double(forKey: key))
    }
    static let fullRadius: CGFloat = 26
    static let finalRadius: CGFloat = 18
    static let boxPadding: CGFloat = 16              // 16 px top, bottom, left, right
    static let finalLabelSize: CGFloat = 12.5
    static let smallLabelSize: CGFloat = 10

    // MARK: - The live transcript
    //
    // The wide box, box above, one row below it: the clock, then one line of speech. See
    // design/hud-transcript-v3.html — the board is the spec, and the reveal maths is in `TranscriptReveal`.
    static let liveBox = CGSize(width: 330, height: 156)
    /// The transcript's type. The same size as the pill's label: it is the same kind of text, arriving early.
    static let transcriptSize: CGFloat = 12.5
    /// One line's frame, never wrapped. Older words slide out to the left behind `transcriptFade`.
    static let transcriptLineHeight: CGFloat = 17
    static let transcriptFade: CGFloat = 34
    /// How far the whole line drifts left as each word lands, so it floats rather than jumping.
    static let transcriptGlide: CGFloat = 9
    /// Provisional ink: the newest word or two, which a later snapshot can still change.
    static let transcriptFreshAlpha: CGFloat = 0.66
    static let transcriptInkAlpha: CGFloat = 0.96
    /// The clock beside the transcript: dim, tabular, and held to a fixed width so a five-digit count cannot
    /// shove the words sideways.
    static let transcriptClockAlpha: CGFloat = 0.5
    static let clockWidth: CGFloat = 30
    static let transcriptWordGap: CGFloat = 5
    /// A word arrives out of a blur, rising into place — the amounts the board draws.
    static let transcriptBlur: CGFloat = 5
    static let transcriptRise: CGFloat = 7
    static let transcriptScale: CGFloat = 0.96

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
        case .loading:
            // Grey, steady, and the other way round: a wait, not a state of the voice.
            return HudVisual(tint: HudSpec.grey, spin: HudSpec.loadingSpin, orb: 1, alpha: 1)
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

    /// The box a state holds before it collapses.
    ///
    /// Recording and working share the wide one: they are the same moment to the person watching — the take is
    /// live — and the pill only appears once there is a result. Sharing it also means the box does not jump when
    /// the engine starts thinking, which it would if working fell back to the square.
    ///
    /// The width is not decoration. One line of speech at 12.5 pt is about 260 pt, and the 104 pt square that
    /// holds an orb and a clock cannot hold it.
    static func fullSize(for state: HudState) -> CGSize {
        switch state {
        case .recording, .working: return HudSpec.liveBox
        default: return CGSize(width: HudSpec.fullBox, height: HudSpec.fullBox)
        }
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
        let full = fullSize(for: state)
        let w = full.width + (target.width - full.width) * e
        let h = full.height + (target.height - full.height) * e
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
