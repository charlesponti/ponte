import AppKit
import SwiftUI
import WaveformCore
import WaveformUI

/// The app's mark, drawn with `WaveformUI`'s orb — so the icon is the thing the app is, and the
/// codebase has one dot-drawing path rather than one per renderer.
enum IconMark: String, CaseIterable {
    /// The sphere exactly as the HUD draws it.
    case orb
    /// A solid core with a dotted halo: the quietest mark, and the clearest at 16 px.
    case core

    var summary: String {
        switch self {
        case .orb: return "the sphere, as the HUD draws it"
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

    /// The menu bar mark: not the dot sphere — at 18 pt the dots average into a fuzzy disc with no
    /// readable silhouette — but the sphere's outline, a core and a ring, as a template image the
    /// system tints for a light or a dark bar.
    static func menuBarImage(pointSize: CGFloat = 18) -> NSImage {
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
        let side = CGFloat(pixels)
        let centre = CGPoint(x: side / 2, y: side / 2)
        let ringRadius = side * 0.42
        let coreRadius = side * 0.20
        let stroke = max(1, side * 0.078)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: CGRect(x: centre.x - coreRadius, y: centre.y - coreRadius,
                                   width: coreRadius * 2, height: coreRadius * 2))
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(stroke)
        ctx.strokeEllipse(in: CGRect(x: centre.x - ringRadius, y: centre.y - ringRadius,
                                     width: ringRadius * 2, height: ringRadius * 2))
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
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
