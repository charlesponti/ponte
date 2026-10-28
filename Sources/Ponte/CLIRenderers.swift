import AppKit
import SwiftUI
import WaveformCore
import WaveformUI
import Foundation

func defaultHudText(for state: HudState) -> String {
    switch state {
    case .idle, .working: return "…"
    case .recording: return "0:07"
    case .done: return "Pasted ✓"
    case .error: return "Heard nothing"
    case .cancelled: return "Cancelled"
    case .loading: return "Loading — 43%"
    }
}

/// Colours a rendered state can be asked for by name, matching what the app passes at the call site.
func hudNamedColour(_ name: String) -> NSColor? {
    switch name {
    case "amber": return HudSpec.amber
    case "red": return HudSpec.red
    case "green": return HudSpec.green
    case "grey": return HudSpec.grey
    case "blue-grey": return HudSpec.blueGrey
    case "dim": return NSColor.white.withAlphaComponent(0.55)
    default: return nil
    }
}

func hudColour(for state: HudState) -> NSColor {
    switch state {
    case .done: return HudSpec.green
    case .error: return HudSpec.red
    case .cancelled: return HudSpec.grey
    case .loading: return HudSpec.blueGrey
    default: return NSColor.white.withAlphaComponent(0.55)
    }
}

@discardableResult
func writePNG(_ image: NSImage, to path: String) -> Int32 {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("error: could not encode PNG")
        return 1
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        return 0
    } catch {
        print("error: \(error.localizedDescription)")
        return 1
    }
}

/// The HUD at one moment, drawn by the app's own SwiftUI view.
func hudImage(state: HudState, t: TimeInterval, text: String, colour: Color,
              ring: ColumnRing, turning: Bool = false, scale: CGFloat = 2,
              live: LiveText = LiveText(), recordedFor: TimeInterval = 0) -> NSImage {
    // Rendering SwiftUI is main-actor work; the CLI is on the main thread.
    MainActor.assumeIsolated {
        let renderer = ImageRenderer(content: HudBox(
            state: state, t: t, label: text, labelColour: colour,
            target: HudLifecycle.pillSize(for: text), ring: ring, clock: nil, turning: turning,
            live: live, recordedFor: recordedFor))
        renderer.scale = scale
        return renderer.nsImage
            ?? NSImage(size: NSSize(width: HudSpec.fullBox, height: HudSpec.fullBox))
    }
}

/// A ring holding one steady level, for a still of the orb answering a voice.
func voiceRing(level: Float, columns: Int = 140) -> ColumnRing {
    let ring = ColumnRing(capacity: 256)
    for _ in 0..<columns {
        ring.append(Column(low: -level, high: level, rms: level, level: level))
    }
    return ring
}

/// A ring holding a train of syllables, offset by `phase`, so a still shows rings along the sphere.
func syllableRing(phase: Double, columns: Int = 140) -> ColumnRing {
    let ring = ColumnRing(capacity: 256)
    for index in 0..<columns {
        let secondsAgo = Double(columns - index) / HudSpec.columnsPerSecond
        let envelope = abs(sin((secondsAgo + phase) * .pi / 0.25))
        let level = Float(max(0, envelope - 0.2) / 0.8)
        ring.append(Column(low: -level, high: level, rms: level, level: level))
    }
    return ring
}

/// The lifecycle as a contact sheet, drawn by the app's own renderer.
func writeHUDSheet(to path: String) -> Int32 {
    struct Frame { let t: Double; let spin: Float; var note: String = "" }
    struct Row { let title: String; let state: HudState; let text: String; let colour: Color; let frames: [Frame] }

    let rows: [Row] = [
        Row(title: "Done — the box collapses to text + 16 px", state: .done,
            text: defaultHudText(for: .done), colour: Color(nsColor: HudSpec.green),
            frames: [Frame(t: 0.00, spin: 1.10), Frame(t: 0.15, spin: 1.30), Frame(t: 0.30, spin: 1.50),
                     Frame(t: 0.45, spin: 1.70), Frame(t: 0.60, spin: 1.85), Frame(t: 0.70, spin: 1.95)]),
        Row(title: "Error — three throbs, then the box follows", state: .error,
            text: defaultHudText(for: .error), colour: Color(nsColor: HudSpec.red),
            // A trough is included next to a peak: the throb is a 15 % scale change, and
            // without both you cannot see it in a still.
            frames: [Frame(t: 0.00, spin: 1.10, note: "mint"),
                     Frame(t: 0.18, spin: 1.25, note: "red"),
                     Frame(t: 0.43, spin: 1.30, note: "trough"),
                     Frame(t: 0.64, spin: 1.35, note: "throb 1 peak"),
                     Frame(t: 1.06, spin: 1.45, note: "throb 2 peak"),
                     Frame(t: 1.48, spin: 1.55, note: "throb 3 peak"),
                     Frame(t: 1.92, spin: 1.70, note: "exiting"),
                     Frame(t: 2.20, spin: 1.80, note: "text only")]),
    ]

    return writeSheet(rows.map { row in
        SheetRow(title: row.title, cells: row.frames.map { frame in
            let geometry = HudLifecycle.geometry(row.state, frame.t,
                                                 target: HudLifecycle.pillSize(for: row.text))
            var caption = String(format: "%.2fs  box %.0f×%.0f", frame.t,
                                 geometry.box.width, geometry.box.height)
            if !frame.note.isEmpty { caption += "  " + frame.note }
            return SheetCell(caption: caption,
                             image: hudImage(state: row.state, t: frame.t, text: row.text,
                                             colour: row.colour, ring: IconRenderer.silentRing))
        })
    }, to: path)
}

/// The orb answering a voice: a row of steady levels, and a row of a word being spoken.
func writeVoiceSheet(to path: String) -> Int32 {
    let dim = Color.white.opacity(0.55)

    let levels = SheetRow(
        title: "The orb answers the level (silence → full voice)",
        cells: [0.0, 0.25, 0.5, 0.75, 1.0].map { level in
            SheetCell(caption: String(format: "level %.2f  →  dots ×%.2f", level,
                                      1 + Double(HudSpec.orbGain) * level),
                      image: hudImage(state: .recording, t: 7, text: "", colour: dim,
                                      ring: voiceRing(level: Float(level))))
        })
    let word = SheetRow(
        title: "A word being spoken: 0.8 s of voice, equator (now) to poles (0.8 s ago)",
        cells: [0.0, 0.2, 0.4, 0.6, 0.8, 1.0].map { moment in
            SheetCell(caption: String(format: "%.2f s in", moment),
                      image: hudImage(state: .recording, t: 7, text: "", colour: dim,
                                      ring: syllableRing(phase: moment)))
        })
    return writeSheet([levels, word], to: path)
}

struct SheetCell {
    let caption: String
    let image: NSImage
}

struct SheetRow {
    let title: String
    let cells: [SheetCell]
}

/// One strip of menu bar with a mark on it, tinted the way the system would tint it.
func menuBarCell(_ mark: MenuBarMark, dark: Bool, tint: NSColor? = nil, level: CGFloat = 0,
                 width: CGFloat = 176, height: CGFloat = 44) -> NSImage {
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bar = dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
                   : NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1)
    bar.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    let mark_ = IconRenderer.menuBarImage(mark, pointSize: 16, level: level)  // the size the bar actually wears
    // A template image carries no colour: the system paints it, white on a dark bar and black on a
    // light one. That is what this reproduces, and how a state colour gets applied.
    let ink = tint ?? (dark ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.82))
    let tinted = NSImage(size: mark_.size)
    tinted.lockFocus()
    mark_.draw(in: NSRect(origin: .zero, size: mark_.size))
    ink.setFill()
    NSRect(origin: .zero, size: mark_.size).fill(using: .sourceIn)
    tinted.unlockFocus()
    tinted.draw(in: NSRect(x: (width - mark_.size.width) / 2, y: (height - mark_.size.height) / 2,
                           width: mark_.size.width, height: mark_.size.height))
    NSGraphicsContext.restoreGraphicsState()
    return tinted
}

/// Every candidate mark, at the size the menu bar really draws it, on a light and a dark bar and in
/// the two states that used to borrow SF Symbols.
func writeMenuBarSheet(_ path: String) -> Int32 {
    let states: [(String, Bool, NSColor?, CGFloat)] = [
        ("light bar", false, nil, 0),
        ("dark bar", true, nil, 0),
        ("recording", true, NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1), 0),
        ("working", true, NSColor(srgbRed: 1.0, green: 0.58, blue: 0.0, alpha: 1), 0),
    ]
    var rows: [SheetRow] = MenuBarMark.allCases.map { mark in
        SheetRow(title: "\(mark.rawValue)  —  \(mark.summary)",
                 cells: states.map { state in
                     SheetCell(caption: state.0,
                               image: menuBarCell(mark, dark: state.1, tint: state.2, level: state.3))
                 })
    }
    // The two marks that answer the voice, which is the point of them: silence to full voice.
    let levels: [CGFloat] = [0.0, 0.25, 0.5, 0.75, 1.0]
    for mark in [MenuBarMark.pulseCore, .levelBars] {
        rows.append(SheetRow(title: "\(mark.rawValue) with the voice, at five levels",
                             cells: levels.map { level in
                                 SheetCell(caption: String(format: "level %.2f", level),
                                           image: menuBarCell(mark, dark: true, tint:
                                               NSColor(srgbRed: 0.4, green: 0.83, blue: 0.81, alpha: 1),
                                                              level: level))
                             }))
    }
    return writeSheet(rows, to: path, cellW: 200, cellH: 64, pad: 30,
                      titleH: 28, captionH: 24, rowGap: 12)
}

/// Draws a contact sheet of pre-rendered frames, two pixels per point.
func writeSheet(_ rows: [SheetRow], to path: String,
                cellW: CGFloat = 152, cellH: CGFloat = 124, pad: CGFloat = 26,
                titleH: CGFloat = 30, captionH: CGFloat = 30, rowGap: CGFloat = 14) -> Int32 {
    let maxFrames = rows.map(\.cells.count).max() ?? 1
    let width = pad * 2 + CGFloat(maxFrames) * cellW
    let height = pad * 2 + CGFloat(rows.count) * (titleH + cellH + captionH + rowGap)
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        print("error: could not create the sheet")
        return 1
    }
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSColor(srgbRed: 0.043, green: 0.043, blue: 0.051, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        .foregroundColor: NSColor.white]
    let captionAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor.white.withAlphaComponent(0.55)]

    var y = height - pad
    for row in rows {
        y -= titleH
        row.title.draw(at: CGPoint(x: pad, y: y + 8), withAttributes: titleAttrs)
        y -= cellH
        for (index, cell) in row.cells.enumerated() {
            let x = pad + CGFloat(index) * cellW
            let box = cell.image.size
            cell.image.draw(in: CGRect(x: x + (cellW - box.width) / 2,
                                       y: y + (cellH - box.height) / 2,
                                       width: box.width, height: box.height))
            cell.caption.draw(at: CGPoint(x: x + 8, y: y - 16), withAttributes: captionAttrs)
        }
        y -= captionH + rowGap
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("error: could not encode PNG")
        return 1
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        return 0
    } catch {
        print("error: \(error.localizedDescription)")
        return 1
    }
}

/// Every mark at the sizes an icon is actually seen at — rendered at true pixel size, then
/// drawn enlarged, so a 32 px tile is judged as a 32 px tile and not as a zoomed drawing.
func writeIconSheet(to path: String) -> Int32 {
    let sizes: [CGFloat] = [512, 256, 128, 64, 32, 16]
    let rows = IconMark.allCases.map { mark in
        SheetRow(title: "\(mark.rawValue) — \(mark.summary)",
                 cells: sizes.map { size in
                    SheetCell(caption: "\(Int(size)) px",
                              image: MainActor.assumeIsolated { IconRenderer.image(mark, size: size) })
                 })
    }
    return writeSheet(rows, to: path, cellW: 268, cellH: 268, pad: 30,
                      titleH: 34, captionH: 26, rowGap: 18)
}

