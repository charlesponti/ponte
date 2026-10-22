import AppKit
import simd

// MARK: - The orb's maths
//
// Ported from ~/Developer/Waveform (OrbModel / OrbProjection) so the app's orb is the
// same object, not a lookalike:
//   · dots evenly on a sphere, spaced by the golden angle
//   · `age` runs 0 at the equator (newest) to 1 at the poles (oldest)
//   · spin about the vertical axis, tipped 0.35 rad toward the viewer
//   · four depth layers at opacity [0.18, 0.4, 0.7, 1.0], near dots drawn larger
//   · radius = min(w,h)/2 / (1 + gain) * 0.94, dot radius 0.62 at full size

struct OrbLattice {
    let count: Int
    /// Each dot's place on the unit sphere. y is up.
    let unit: [SIMD3<Float>]
    /// 0 at the equator to 1 at a pole.
    let age: [Float]

    init(count: Int) {
        precondition(count > 1)
        self.count = count
        var unit: [SIMD3<Float>] = []
        var age: [Float] = []
        unit.reserveCapacity(count)
        age.reserveCapacity(count)
        let golden = Float.pi * (3 - Float(5).squareRoot())
        for i in 0..<count {
            let y = 1 - 2 * (Float(i) + 0.5) / Float(count)
            let ring = (1 - y * y).squareRoot()
            let angle = golden * Float(i)
            unit.append(SIMD3(cos(angle) * ring, y, sin(angle) * ring))
            age.append(abs(asin(y)) / (.pi / 2))
        }
        self.unit = unit
        self.age = age
    }
}

enum OrbProjection {
    static let tip: Float = 0.35
    static let opacities: [CGFloat] = [0.18, 0.4, 0.7, 1.0]
    /// How far full scale pushes a dot out, as a fraction of the resting radius.
    ///
    /// Waveform uses 0.45 in a canvas of its own; here the orb shares a fixed 96 px box with a label
    /// underneath, and 0.45 would push the dots into it. At 0.25 the *loudest* voice lands on exactly
    /// the 60 px orb the design board draws and a quiet room is a smaller, calmer sphere.
    static let gain: Float = 0.25

    /// Where the dot at unit-sphere position `u`, pushed out to `out` times the radius,
    /// lands: x and y in units of the radius (y up), and depth 0 far to 1 near.
    static func place(_ u: SIMD3<Float>, out: Float, spin: Float) -> (x: Float, y: Float, depth: Float) {
        let sy = sin(spin), cy = cos(spin)
        let sx = sin(tip), cx = cos(tip)
        let x1 = u.x * cy + u.z * sy
        let z1 = -u.x * sy + u.z * cy
        let y2 = u.y * cx - z1 * sx
        let z2 = u.y * sx + z1 * cx
        return (x1 * out, y2 * out, (z2 + 1) / 2)
    }

    static func layer(depth: Float) -> Int { min(3, Int(depth * 4)) }
    static func perspective(depth: Float) -> Float { 0.75 + 0.25 * depth }
    static func radius(in size: CGFloat) -> Float {
        Float(min(size, size)) / 2 / (1 + gain) * 0.94
    }
}

/// What one dot shows: how loud the sound at its age was, and how high its peak was.
/// Both are already in display units (0...1), the same scale Waveform's `Scale.decibels` produces.
struct VoiceColumn {
    var level: Float = 0
    var peak: Float = 0
}

/// The last second or so of the voice, one entry per meter tick, read at any fractional age.
///
/// Waveform keeps a ring of 120 columns a second and reads it with a Catmull-Rom curve through the
/// four neighbours, so the motion has no corners as the playhead moves between entries. VoiceNote's
/// meter ticks 30 times a second, so the ring is coarser — the curve is what keeps it smooth.
final class LevelRing {
    private var slots: [VoiceColumn]
    private var written = 0
    private let capacity: Int

    init(capacity: Int = 128) {
        self.capacity = capacity
        slots = Array(repeating: VoiceColumn(), count: capacity)
    }

    /// Total columns ever appended.
    var head: Int { written }

    func reset() {
        slots = Array(repeating: VoiceColumn(), count: capacity)
        written = 0
    }

    func append(level: Float, peak: Float) {
        slots[written % capacity] = VoiceColumn(level: level, peak: peak)
        written += 1
    }

    /// Level and peak at an absolute column position, fractional, oldest history clamped to silence.
    func sample(at position: Double) -> (level: Float, peak: Float) {
        let i = Int(position.rounded(.down))
        let t = Float(position - Double(i))
        func at(_ k: Int) -> VoiceColumn {
            guard k >= 0, k < written, k > written - capacity else { return VoiceColumn() }
            return slots[k % capacity]
        }
        let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
        return (max(0, Self.catmullRom(p0.level, p1.level, p2.level, p3.level, t)),
                max(0, min(1, Self.catmullRom(p0.peak, p1.peak, p2.peak, p3.peak, t))))
    }

    /// The curve through p1 (at t = 0) and p2 (at t = 1), shaped by the points either side.
    static func catmullRom(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
            + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
    }
}

/// What a dot of a given age shows, for the renderer and for offscreen pictures.
typealias VoiceProfile = (Float) -> (level: Float, peak: Float)

/// Draws the orb. One pass per depth layer, so 1,100 dots cost four fills a frame.
enum OrbRenderer {
    static let lattice = OrbLattice(count: 1100)
    static let fullSize: CGFloat = 64
    static let baseDotRadius: CGFloat = 0.62

    static func draw(in ctx: CGContext, center: CGPoint, size: CGFloat,
                     tint: NSColor, alpha: CGFloat, spin: Float, voice: VoiceProfile? = nil) {
        guard size >= 1.5, alpha > 0.01 else { return }
        let radius = OrbProjection.radius(in: size)
        // The whole object scales, so the dots scale with it rather than shedding.
        let dotRadius = max(0.32, baseDotRadius * (size / fullSize))
        var layers = [[(CGPoint, CGFloat)]](repeating: [], count: 4)
        for i in 0..<lattice.count {
            // The dot at this age shows the sound that many columns back: silence is a plain sphere,
            // a loud moment pushes dots out, and a high peak makes them bigger.
            // `voice` reports the level itself (0...1); how far that pushes a dot is the gain's job.
            let (level, peak) = voice?(lattice.age[i]) ?? (0, 0)
            let out = 1 + OrbProjection.gain * level
            let p = OrbProjection.place(lattice.unit[i], out: out, spin: spin)
            let depth = p.depth
            let dotScale = (1.1 + 2.4 * peak + (out - 1)) / 1.1
            let r = dotRadius * CGFloat(OrbProjection.perspective(depth: depth)) * CGFloat(dotScale)
            layers[OrbProjection.layer(depth: depth)].append(
                (CGPoint(x: center.x + CGFloat(p.x) * CGFloat(radius),
                         y: center.y - CGFloat(p.y) * CGFloat(radius)), max(0.3, r)))
        }
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        for (index, dots) in layers.enumerated() where !dots.isEmpty {
            let path = CGMutablePath()
            for (c, r) in dots {
                path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            ctx.addPath(path)
            ctx.setFillColor(tint.withAlphaComponent(alpha * OrbProjection.opacities[index]).cgColor)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }
}

// MARK: - The lifecycle

enum HudState: String {
    case idle, recording, working, done, error
}

/// Every colour and duration of the lifecycle, in one place. These are the numbers from
/// design/hud-b-lifecycle-v2.html — the board is the spec.
enum HudSpec {
    // tints, exactly as the board draws them
    static let mint = NSColor(srgbRed: 102 / 255, green: 212 / 255, blue: 207 / 255, alpha: 1)
    static let green = NSColor(srgbRed: 50 / 255, green: 215 / 255, blue: 75 / 255, alpha: 1)
    static let red = NSColor(srgbRed: 255 / 255, green: 69 / 255, blue: 58 / 255, alpha: 1)

    static let baseSpin: Float = 0.35                // rad/s, the model's own rate
    static let recordingSpinMultiple: Float = 4      // "spins fast" while recording
    static let workingSpin: Float = 0.35             // calm

    // What the box is made of. Black, not the usual translucent `.hudWindow` material: the orb's
    // outer dots are drawn at 18 % and vanish against a grey blur. The face and the hairline are here
    // so the app and the offscreen renders cannot drift apart.
    static let boxFill = NSColor.black
    static let boxFillAlpha: CGFloat = 0.94
    static let boxBorderAlpha: CGFloat = 0.12

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

    /// How much of the past the orb spans, equator to pole (Waveform's `historySeconds`).
    static let voiceHistory: Double = 0.8
    /// How often the meter ticks. Waveform uses 120 columns a second from the audio itself; the
    /// recorder's meter is 30, and the Catmull-Rom read is what hides the difference.
    static let voiceRate: Double = 30
    /// How long the level takes to fall by about 63% once the sound stops (Waveform's `releaseSeconds`).
    static let voiceRelease: Double = 0.15
    /// Columns the orb spans, equator to pole.
    static var voiceColumns: Double { voiceHistory * voiceRate }
}

struct HudVisual {
    var tint: NSColor
    var spin: Float
    var orb: CGFloat        // orb scale, 0...1 of 64 px
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
            orbPx: OrbRenderer.fullSize * v.orb,
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
        default: return nil
        }
    }

    /// The recording clock: counts up from nothing, m:ss.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
