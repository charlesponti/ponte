import AppKit

/// The app's mark, drawn with the app's own orb renderer — the icon is the thing the app is,
/// not a drawing of a microphone.
enum IconMark: String, CaseIterable {
    /// The sphere exactly as the HUD shows it.
    case orb
    /// The same sphere drawn as rows of dots: a halftone screen.
    case halftone
    /// The sphere with rings leaving it — sound on its way out.
    case ripple
    /// A solid core with a dotted halo: the quietest version, and the clearest at 16 px.
    case core
}

enum IconRenderer {
    /// The canvas Apple's icon grid is drawn on.
    static let canvas: CGFloat = 1024
    /// The squircle inside it: 824 × 824, radius 185, as macOS wants.
    static let bodyInset: CGFloat = 100
    static let bodyRadius: CGFloat = 185

    static let face = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.047, alpha: 1)
    /// The mark is the same drawing at every size, but the dots grow *relative to the sphere* as
    /// the tile shrinks. Otherwise a 1 px dot averages into the gaps beside it and a dotted sphere
    /// is a grey smudge at 64 px and nothing at 16 px. This is the icon equivalent of a hint.
    static func dotScale(_ base: CGFloat, size: CGFloat) -> CGFloat {
        base * min(4, max(1, pow(512 / max(size, 16), 0.30)))
    }

    /// Exactly `size` pixels, not `size` points: an icon is judged at its real pixel size, so a
    /// 32 px tile must be 32 px wide and not a 32 pt drawing on a retina rep.
    /// The menu bar mark: the same sphere in monochrome, marked as a template so the system tints
    /// it for a light or dark menu bar. Only alpha survives a template, so the dots are black.
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
        // Not the dot sphere: at 18 pt the dots average into a fuzzy disc with no readable
        // silhouette. The menu bar gets the sphere's *outline* instead — a core and a ring, which
        // is what survives at menu bar size, and the same mark the app icon simplifies to.
        //
        // This context is in *pixels* (the rep is 2x); rep.size only says how big it displays.
        // Sizing from `pointSize` here drew the mark in the bottom-left quadrant at half size.
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

    static func image(_ mark: IconMark, size: CGFloat = canvas) -> NSImage {
        let pixels = Int(size.rounded())
        let image = NSImage(size: CGSize(width: pixels, height: pixels))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let ctx = graphics.cgContext
        ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
        ctx.setShouldAntialias(true)
        draw(mark, in: ctx, pixelSize: size)
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }

    /// `pixelSize` is the tile's real pixel width and is used for the dot hint only; all the
    /// geometry below is in the 1024 pt canvas the context has already been scaled to.
    static func draw(_ mark: IconMark, in ctx: CGContext, pixelSize: CGFloat = IconRenderer.canvas) {
        let size = canvas
        let body = CGRect(x: bodyInset, y: bodyInset,
                          width: size - bodyInset * 2, height: size - bodyInset * 2)
        let centre = CGPoint(x: size / 2, y: size / 2)
        let radius = body.width / 2

        // The face: opaque, near-black, with the same hairline the HUD box has.
        let face = CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius,
                          transform: nil)
        ctx.addPath(face)
        ctx.setFillColor(Self.face.cgColor)
        ctx.fillPath()

        // A whisper of light from the top, so the squircle reads as a surface and not a hole.
        if let sheen = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor.white.withAlphaComponent(0.07).cgColor,
                     NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]) {
            ctx.saveGState()
            ctx.addPath(face)
            ctx.clip()
            ctx.drawRadialGradient(sheen,
                                   startCenter: CGPoint(x: centre.x, y: size * 0.78), startRadius: 0,
                                   endCenter: CGPoint(x: centre.x, y: size * 0.62), endRadius: radius * 1.5,
                                   options: [])
            ctx.restoreGState()
        }

        let mint = HudSpec.mint

        // The glow the orb sits in.
        if let glow = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [mint.withAlphaComponent(0.26).cgColor,
                     mint.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]) {
            ctx.saveGState()
            ctx.addPath(face)
            ctx.clip()
            ctx.drawRadialGradient(glow,
                                   startCenter: centre, startRadius: 0,
                                   endCenter: centre, endRadius: radius * 0.92,
                                   options: [])
            ctx.restoreGState()
        }

        switch mark {
        case .orb:
            OrbRenderer.draw(in: ctx, center: centre, size: radius * 1.46,
                             tint: mint, alpha: 1, spin: 1.1,
                             lattice: OrbLattice(count: 240), dotScale: dotScale(2.6, size: pixelSize))

        case .halftone:
            // Rows that thin toward the poles: a halftone screen wrapped on a sphere.
            let rows = OrbLattice.rows(rings: 15) { row in
                max(8, Int((26 * sin(.pi * Double(row) / 15)).rounded()))
            }
            OrbRenderer.draw(in: ctx, center: centre, size: radius * 1.46,
                             tint: mint, alpha: 1, spin: 1.1,
                             lattice: rows, dotScale: dotScale(2.4, size: pixelSize))

        case .ripple:
            OrbRenderer.draw(in: ctx, center: centre, size: radius * 1.02,
                             tint: mint, alpha: 1, spin: 1.1,
                             lattice: OrbLattice(count: 240), dotScale: dotScale(2.4, size: pixelSize))
            // Rings on their way out, each fainter and finer than the last.
            for (index, ring) in [(1.34, 0.55, 9.0), (1.66, 0.34, 7.5), (1.96, 0.18, 6.0)].enumerated() {
                let (multiple, alpha, dotRadius) = ring
                let ringRadius = radius * 0.44 * CGFloat(multiple)
                let count = 84 + index * 18
                for i in 0..<count {
                    let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(count)
                    let point = CGPoint(x: centre.x + cos(angle) * ringRadius,
                                        y: centre.y + sin(angle) * ringRadius)
                    ctx.setFillColor(mint.withAlphaComponent(alpha).cgColor)
                    ctx.fillEllipse(in: CGRect(x: point.x - dotRadius / 2, y: point.y - dotRadius / 2,
                                               width: dotRadius, height: dotRadius))
                }
            }

        case .core:
            // A solid core with a halo: reads at 16 px, where dots become dust.
            let coreRadius = radius * 0.42
            if let core = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [NSColor(srgbRed: 0.62, green: 0.94, blue: 0.93, alpha: 1).cgColor,
                         mint.withAlphaComponent(0.72).cgColor] as CFArray,
                locations: [0, 1]) {
                ctx.saveGState()
                ctx.addEllipse(in: CGRect(x: centre.x - coreRadius, y: centre.y - coreRadius,
                                          width: coreRadius * 2, height: coreRadius * 2))
                ctx.clip()
                ctx.drawRadialGradient(core,
                                       startCenter: CGPoint(x: centre.x - coreRadius * 0.3,
                                                            y: centre.y + coreRadius * 0.4),
                                       startRadius: 0,
                                       endCenter: centre, endRadius: coreRadius * 1.15,
                                       options: [])
                ctx.restoreGState()
            }
            let halo = radius * 0.62
            for i in 0..<72 {
                let angle = 2 * CGFloat.pi * CGFloat(i) / 72
                let point = CGPoint(x: centre.x + cos(angle) * halo,
                                    y: centre.y + sin(angle) * halo)
                ctx.setFillColor(mint.withAlphaComponent(0.5).cgColor)
                ctx.fillEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            }
        }
    }
}
