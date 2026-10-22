import AppKit
import XCTest
@testable import Ponte

/// Reading what a renderer actually drew, rather than trusting that it drew.
///
/// The app's own bugs were caught this way: an orb that collapsed as the voice got louder, and an
/// icon that smeared into a grey disc at small sizes. Both looked fine in a still.
struct Ink {
    var count = 0
    var bounds = CGRect.zero
    /// Brightest composited value of the mark's colour, 0...1.
    var peak: CGFloat = 0
    /// Tenth-percentile brightness: low on a shaded sphere, high on a flat disc.
    var p10: CGFloat = 0
    var coverage: Double { Double(count) / Double(max(1, bounds.width * bounds.height)) }

    /// Ink in the top part of the image only, for shapes with a label underneath.
    func bounds(inTop fraction: CGFloat, of imageSize: CGSize) -> CGRect {
        bounds.intersection(CGRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height * fraction))
    }
}

enum Probe {
    /// A drawing surface of exactly `pixels` pixels, whatever the display scale is. Measurements
    /// taken through `lockFocus` depend on the machine's screen and are not reproducible.
    static func image(pixels: Int, draw: (CGContext) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.setShouldAntialias(true)
        draw(graphics.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }

    /// Pixels where green dominates red: mint ink, and nothing else the app draws.
    static func mint(_ image: NSImage) -> Ink {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let data = rep.bitmapData else { return Ink() }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let step = rep.samplesPerPixel, stride = rep.bytesPerRow
        var ink = Ink()
        var histogram = [Int](repeating: 0, count: 256)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = data + y * stride
            for x in 0..<width {
                let p = row + x * step
                let r = CGFloat(p[0]) / 255, g = CGFloat(p[1]) / 255
                // premultiplied, so this is the colour as composited over the face
                guard g - r > 0.04 else { continue }
                ink.count += 1
                ink.peak = max(ink.peak, g)
                histogram[min(255, Int(g * 255))] += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        if maxX >= 0 {
            ink.bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            let target = max(1, ink.count / 10)
            var running = 0
            for value in 0..<256 {
                running += histogram[value]
                if running >= target { ink.p10 = CGFloat(value) / 255; break }
            }
        }
        return ink
    }

    /// Any ink at all, whatever the colour: for template images, which are black.
    static func anyInk(_ image: NSImage, alphaAbove: CGFloat = 0.2) -> Ink {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let data = rep.bitmapData else { return Ink() }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let step = rep.samplesPerPixel, stride = rep.bytesPerRow
        var ink = Ink()
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = data + y * stride
            for x in 0..<width {
                let p = row + x * step
                let a = CGFloat(p[3]) / 255
                guard a > alphaAbove else { continue }
                ink.count += 1
                ink.peak = max(ink.peak, a)
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        if maxX >= 0 {
            ink.bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        return ink
    }

    /// Alpha at one pixel, for probing structure (a hole, a corner).
    static func alpha(_ image: NSImage, atX x: Int, y: Int) -> CGFloat {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let data = rep.bitmapData, x >= 0, y >= 0,
              x < rep.pixelsWide, y < rep.pixelsHigh else { return 0 }
        return CGFloat((data + y * rep.bytesPerRow + x * rep.samplesPerPixel)[3]) / 255
    }
}

extension XCTestCase {
    /// sRGB components, so comparisons do not depend on the colour space a test runs in.
    func srgb(_ colour: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = colour.usingColorSpace(.sRGB) ?? colour
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    func assertColour(_ colour: NSColor, is expected: NSColor, accuracy: CGFloat = 0.02,
                      _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let a = srgb(colour), b = srgb(expected)
        XCTAssertEqual(a.r, b.r, accuracy: accuracy, "red channel: \(message)", file: file, line: line)
        XCTAssertEqual(a.g, b.g, accuracy: accuracy, "green channel: \(message)", file: file, line: line)
        XCTAssertEqual(a.b, b.b, accuracy: accuracy, "blue channel: \(message)", file: file, line: line)
    }
}
