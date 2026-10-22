import AppKit
import SwiftUI
import WaveformCore
import WaveformUI

/// The app's mark, drawn with `WaveformUI`'s orb — so the icon is the thing the app is, and the
/// codebase has one dot-drawing path rather than one per renderer.
enum IconMark: String, CaseIterable {
    /// The sphere exactly as the HUD draws it, through `WaveformUI` — the shared view.
    case orb
    /// The same sphere drawn as rows of dots, like a halftone screen.
    case halftone
    /// The sphere with rings leaving it: sound on its way out.
    case ripple
    /// A solid core with a dotted halo: the quietest mark, and the clearest at 16 px.
    case core

    var summary: String {
        switch self {
        case .orb: return "the sphere, as the HUD draws it"
        case .halftone: return "the same sphere as rows of dots"
        case .ripple: return "the sphere with rings leaving it"
        case .core: return "a solid core and a halo"
        }
    }
}

enum IconRenderer {
    /// The canvas Apple's icon grid is drawn on: an 824 pt squircle, radius 185, centred.
    static let canvas: CGFloat = 1024
    static let bodyInset: CGFloat = 100
    static let bodyRadius: CGFloat = 185
    static let face = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.047, alpha: 1)

    /// A still sphere: an empty ring draws a plain orb, which is what the mark is.
    static let silentRing = ColumnRing(capacity: 64)

    /// How much to multiply every dot by at a given tile size.
    ///
    /// `WaveformUI` draws dots at an absolute point size, tuned for an orb a few hundred points
    /// across. A small tile drawn with those same dots covers its sphere twice over and reads as a
    /// solid disc, and a 16 px tile smears. So the dots scale with the tile, plus a nudge that grows
    /// as it shrinks — the icon equivalent of a hint. At 512 px the multiplier is 6.8 (a 7.5 pt dot);
    /// at 16 px it is 0.6, which fills the little sphere instead of dusting it.
    static func dotScale(forTile size: CGFloat) -> Double {
        0.0133 * Double(size) * pow(512 / Double(max(size, 16)), 0.30)
    }

    /// Exactly `size` pixels, not `size` points: an icon is judged at its real pixel size, so a
    /// 32 px tile is 32 px wide and not a 32 pt drawing on a retina rep.
    @MainActor
    static func image(_ mark: IconMark, size: CGFloat = canvas) -> NSImage {
        let renderer = ImageRenderer(content: IconView(mark: mark, size: size))
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else {
            return NSImage(size: NSSize(width: size, height: size))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    /// The menu bar mark, drawn at 18 pt: not the dot sphere — at that size the dots average into a
    /// fuzzy disc with no readable silhouette — but the sphere reduced to shapes that survive.
    /// Template images are alpha only, so the system tints them for a light or a dark bar, and the
    /// same property is what lets a state colour be applied with `contentTintColor`.
    static func menuBarImage(_ mark: MenuBarMark = .coreRing, pointSize: CGFloat = 18,
                             level: CGFloat = 0) -> NSImage {
        let pixels = Int((pointSize * 2).rounded())
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        rep.size = NSSize(width: pointSize, height: pointSize)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let ctx = graphics.cgContext
        ctx.setShouldAntialias(true)
        // This context is in *pixels* (the rep is 2x); rep.size only says how big it displays.
        // Sizing from `pointSize` here once drew the mark in the bottom-left quadrant at half size.
        // Everything below is in pixels: this context is 2x (36 px for an 18 pt mark).
        let side = CGFloat(pixels)
        let centre = CGPoint(x: side / 2, y: side / 2)
        let ink = NSColor.black.cgColor
        ctx.setFillColor(ink)
        ctx.setStrokeColor(ink)

        func dot(_ radius: CGFloat) {
            ctx.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                       width: radius * 2, height: radius * 2))
        }
        func ring(_ radius: CGFloat, width: CGFloat, dash: [CGFloat] = []) {
            ctx.setLineWidth(width)
            ctx.setLineDash(phase: 0, lengths: dash)
            ctx.strokeEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                         width: radius * 2, height: radius * 2))
            ctx.setLineDash(phase: 0, lengths: [])
        }

        switch mark {
        case .coreRing:
            dot(side * 0.20)
            ring(side * 0.42, width: max(1, side * 0.078))
        case .orbEdge:
            dot(side * 0.42)
            // Bite a disc out of it, off centre: what is left is the crescent of a lit sphere.
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: centre.x - side * 0.19, y: centre.y - side * 0.09,
                                       width: side * 0.62, height: side * 0.62))
            ctx.setBlendMode(.normal)
        case .pulseCore:
            // The core swells with the voice, so the menu bar itself is a level meter. It rests big
            // enough not to read as an empty radio button.
            ring(side * 0.42, width: max(1, side * 0.06))
            dot(side * (0.17 + 0.16 * min(max(level, 0), 1)))
        case .speechDot:
            // Sized so the tail is a stroke of the same weight as the body once they touch, rather
            // than a spike hanging off a circle.
            dot(side * 0.29)
            let tail = CGMutablePath()
            tail.move(to: CGPoint(x: centre.x - side * 0.18, y: centre.y - side * 0.09))
            tail.addLine(to: CGPoint(x: centre.x - side * 0.34, y: centre.y - side * 0.34))
            tail.addLine(to: CGPoint(x: centre.x + side * 0.05, y: centre.y - side * 0.24))
            tail.closeSubpath()
            ctx.addPath(tail)
            ctx.fillPath()
        case .levelBars:
            // Three bars, bottom-aligned, each answering the voice a little differently: a meter.
            let width = side * 0.155
            let gap = side * 0.115
            let factors: [CGFloat] = [0.78, 1.0, 0.86]
            let base = side * 0.26      // tall enough that the rest state is not a faint smudge
            let span = side * 0.40 * min(max(level, 0), 1)
            let total = width * 3 + gap * 2
            // The resting group is centred, so the mark is not bottom-heavy in the bar; it then
            // grows upward, which is what a meter does.
            let bottom = centre.y - base / 2
            for (index, factor) in factors.enumerated() {
                let height = base + span * factor
                let x = centre.x - total / 2 + CGFloat(index) * (width + gap)
                let rect = CGRect(x: x, y: bottom, width: width, height: height)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: width / 2,
                                   cornerHeight: width / 2, transform: nil))
                ctx.fillPath()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}

/// The sphere as rows of dots, like a halftone screen. This one is the icon's own decorative mark
/// rather than `WaveformUI`'s orb: the shared view draws the spiral lattice the HUD shows, and a
/// halftone is a different shape — rows — which the view has no way to ask for. Nothing of the audio
/// pipeline is repeated here: no columns, no depth layers, no loudness.
struct HalftoneSphere: View {
    var tint: Color
    /// The tile this mark is drawn on, so the dots can answer its size the way `WaveformUI`'s do.
    var tileSize: CGFloat
    /// The rows seen as a globe: rings of latitude, tilted toward the viewer.
    private let tip = 0.35
    private let rows = 15

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 * 0.94
            // An absolute dot size, like the shared view's: scaled to the tile with the same nudge,
            // or the dots are sub-pixel at 16 px and the mark is a smudge of grey.
            let dot = IconRenderer.dotScale(forTile: tileSize) * 0.9
            for row in 0...rows {
                let latitude = 1 - 2 * Double(row) / Double(rows)   // 1 at the top pole
                for index in 0..<HalftoneSphere.perRow(latitude) {
                    let angle = 2 * Double.pi * Double(index) / Double(HalftoneSphere.perRow(latitude))
                    let ring = (max(0, 1 - latitude * latitude)).squareRoot()
                    let x = ring * cos(angle)
                    let z = ring * sin(angle)
                    // Tilt the sphere toward the viewer, so a pole is visible.
                    let y = latitude * cos(tip) - z * sin(tip)
                    let depth = (latitude * sin(tip) + z * cos(tip) + 1) / 2
                    let point = CGPoint(x: centre.x + CGFloat(x) * radius,
                                        y: centre.y - CGFloat(y) * radius)
                    let r = dot * (0.75 + 0.25 * depth)
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
                        with: .color(tint.opacity(0.35 + 0.6 * depth)))
                }
            }
        }
    }

    /// Fewer dots on the rows near the poles, or they crowd together.
    private static func perRow(_ latitude: Double) -> Int {
        max(6, Int((26 * (max(0, 1 - latitude * latitude)).squareRoot()).rounded()))
    }
}

/// The mark in the menu bar. All are template images: alpha only, tinted by the system for a light or
/// a dark bar, and by `contentTintColor` to say what the app is doing.
enum MenuBarMark: String, CaseIterable {
    /// A core inside a ring — the orb reduced to two strokes.
    case coreRing
    /// The orb itself: a disc with a crescent bitten out of it, the way the sphere's shading reads.
    case orbEdge
    /// A ring whose core swells with the voice: the menu bar as a level meter.
    case pulseCore
    /// A dot with a tail: a speech mark.
    case speechDot
    /// Three bars that answer the voice, like a level meter in miniature.
    case levelBars

    /// Which mark the menu bar draws. Kept as a string so the choice changes without a rebuild:
    /// `defaults write com.ponti.ponte menuBarMark levelBars` and relaunch.
    static var chosen: MenuBarMark {
        MenuBarMark(rawValue: UserDefaults.standard.string(forKey: "menuBarMark") ?? "") ?? .coreRing
    }

    var summary: String {
        switch self {
        case .coreRing: return "a core inside a ring — the current one"
        case .orbEdge: return "the orb as a crescent: a disc with a bite out of it"
        case .pulseCore: return "a ring whose core swells with your voice"
        case .speechDot: return "a dot with a tail, like a speech mark"
        case .levelBars: return "three bars that rise with your voice"
        }
    }
}

/// The icon at `size` points: the squircle, the glow the orb sits in, and the mark.
struct IconView: View {
    var mark: IconMark
    var size: CGFloat

    private var squircle: RoundedRectangle {
        RoundedRectangle(cornerRadius: IconRenderer.bodyRadius * (size / IconRenderer.canvas),
                         style: .continuous)
    }
    private var mint: Color { Color(nsColor: HudSpec.mint) }

    var body: some View {
        ZStack {
            squircle.fill(Color(nsColor: IconRenderer.face))
            // A whisper of light from the top, so the squircle reads as a surface and not a hole.
            RadialGradient(colors: [Color.white.opacity(0.07), .clear],
                           center: UnitPoint(x: 0.5, y: 0.2), startRadius: 0, endRadius: size * 0.75)
                .clipShape(squircle)
            // The glow the orb sits in.
            RadialGradient(colors: [mint.opacity(0.26), .clear],
                           center: .center, startRadius: 0, endRadius: size * 0.36)
                .clipShape(squircle)
            markBody
        }
        .frame(width: size, height: size)
        .clipped()
    }

    @ViewBuilder private var markBody: some View {
        switch mark {
        case .orb:
            OrbView(
                ring: IconRenderer.silentRing, columnsPerSecond: HudSpec.columnsPerSecond, clock: nil,
                scale: .decibels(floor: HudSpec.voiceFloor), gain: HudSpec.orbGain,
                historySeconds: HudSpec.voiceHistory, showStats: false, turning: false,
                tint: mint, dotCount: 240, spinRate: 0, still: 1.1,
                dotScale: IconRenderer.dotScale(forTile: size))
                .frame(width: size * 0.8, height: size * 0.8)

        case .halftone:
            // Slightly tighter than the orb, so the rows read the same size as the sphere beside them.
            HalftoneSphere(tint: mint, tileSize: size)
                .frame(width: size * 0.70, height: size * 0.70)

        case .ripple:
            ZStack {
                OrbView(
                    ring: IconRenderer.silentRing, columnsPerSecond: HudSpec.columnsPerSecond,
                    clock: nil, scale: .decibels(floor: HudSpec.voiceFloor), gain: HudSpec.orbGain,
                    historySeconds: HudSpec.voiceHistory, showStats: false, turning: false,
                    tint: mint, dotCount: 240, spinRate: 0, still: 1.1,
                    dotScale: IconRenderer.dotScale(forTile: size))
                    .frame(width: size * 0.66, height: size * 0.66)
                // Rings on their way out, each fainter and finer than the last.
                ForEach(Array([(0.237, 0.55, 0.0088, 84), (0.294, 0.34, 0.0073, 102),
                               (0.347, 0.18, 0.0059, 120)].enumerated()), id: \.offset) { _, ring in
                    let (radius, opacity, dotSize, count) = ring
                    ForEach(0..<count, id: \.self) { index in
                        let angle = 2 * Double.pi * Double(index) / Double(count)
                        Circle()
                            .fill(mint.opacity(opacity))
                            .frame(width: size * dotSize, height: size * dotSize)
                            .offset(x: CGFloat(cos(angle)) * size * radius,
                                    y: CGFloat(sin(angle)) * size * radius)
                    }
                }
            }

        case .core:
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(.sRGB, red: 0.62, green: 0.94, blue: 0.93, opacity: 1),
                                 mint.opacity(0.72)],
                        center: UnitPoint(x: 0.35, y: 0.65), startRadius: 0, endRadius: size * 0.20))
                    .frame(width: size * 0.34, height: size * 0.34)
                ForEach(0..<72, id: \.self) { index in
                    let angle = 2 * Double.pi * Double(index) / 72
                    Circle()
                        .fill(mint.opacity(0.5))
                        .frame(width: size * 0.010, height: size * 0.010)
                        .offset(x: CGFloat(cos(angle)) * size * 0.25,
                                y: CGFloat(sin(angle)) * size * 0.25)
                }
            }
        }
    }
}
