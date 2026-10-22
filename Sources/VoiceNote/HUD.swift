import AppKit

/// The floating HUD: a squircle holding the orb, which collapses to a text pill when a
/// run finishes. Geometry, colour and timing come from `HudLifecycle` — the board
/// (design/hud-b-lifecycle-v2.html) is the spec.
final class HUD {
    private var panel: NSPanel?
    private var blur: NSVisualEffectView?
    private var content: HudContentView?
    private var link: CADisplayLink?

    private var state: HudState = .idle
    private var startedAt: CFTimeInterval = CACurrentMediaTime()
    private var spin: Float = 1.1
    private var label = "…"
    private var labelColour: NSColor = NSColor.white.withAlphaComponent(0.55)
    private var targetSize = CGSize(width: HudSpec.fullBox, height: HudSpec.fullBox)
    private var hideWork: DispatchWorkItem?

    private let bottomInset: CGFloat = 96
    private let labelDim = NSColor.white.withAlphaComponent(0.55)

    // MARK: - Public

    func beginRecording() {
        set(state: .recording, text: HudLifecycle.clock(0), colour: labelDim)
    }

    /// Working: the orb turns at the model's calm rate, label is an ellipsis.
    func showWorking() {
        set(state: .working, text: "…", colour: labelDim)
    }

    /// A long operation with one number worth showing: the orb plus a percentage.
    func showDownload(percent: Int) {
        set(state: .working, text: "\(percent)%", colour: labelDim)
    }

    func showDone(_ text: String) {
        set(state: .done, text: text, colour: HudSpec.green)
    }

    func showError(_ text: String) {
        set(state: .error, text: text, colour: HudSpec.red)
    }

    func hide() {
        link?.invalidate()
        link = nil
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    // MARK: - State machine

    private func set(state newState: HudState, text: String, colour: NSColor) {
        hideWork?.cancel()
        hideWork = nil
        state = newState
        startedAt = CACurrentMediaTime()
        spin = 1.1
        label = text
        labelColour = colour
        targetSize = HudLifecycle.pillSize(for: text)

        ensurePanel()
        drawFrame(at: 0)
        show()
        startLink()

        if let life = HudLifecycle.lifetime(newState) {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + life, execute: work)
        }
    }

    private func startLink() {
        link?.invalidate()
        guard let content else { return }
        let l = content.displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        let t = CACurrentMediaTime() - startedAt
        // The recording label is a live clock, not a caption.
        if state == .recording {
            let text = HudLifecycle.clock(t)
            if text != label { label = text }
        }
        if let geometry = drawFrame(at: t) {
            spin += geometry.visual.spin * Float(1.0 / 60.0)
        }
    }

    // MARK: - Drawing

    @discardableResult
    private func drawFrame(at t: TimeInterval) -> HudGeometry? {
        guard let panel, let content, let blur else { return nil }
        let geometry = HudLifecycle.geometry(state, t, target: targetSize)
        let size = geometry.box

        // Keep the bottom edge where it has always been, so the box sinks as it collapses.
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return nil }
        let origin = CGPoint(x: (visible.midX - size.width / 2).rounded(),
                             y: (visible.minY + bottomInset).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: false)

        blur.frame = NSRect(origin: .zero, size: size)
        blur.layer?.cornerRadius = geometry.radius
        content.frame = NSRect(origin: .zero, size: size)
        content.geometry = geometry
        content.label = label
        content.labelColour = labelColour
        content.spin = spin
        content.needsDisplay = true
        panel.alphaValue = geometry.hudAlpha
        return geometry
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let side = HudSpec.fullBox
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        container.wantsLayer = true

        let b = NSVisualEffectView(frame: container.bounds)
        b.material = .hudWindow
        b.blendingMode = .behindWindow
        b.state = .active
        b.wantsLayer = true
        b.layer?.cornerRadius = HudSpec.fullRadius
        b.layer?.masksToBounds = true
        b.autoresizingMask = [.width, .height]

        let c = HudContentView(frame: container.bounds)
        c.autoresizingMask = [.width, .height]

        container.addSubview(b)
        container.addSubview(c)
        p.contentView = container

        panel = p
        blur = b
        content = c
    }

    private func show() {
        guard let panel else { return }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    // MARK: - Offscreen rendering, so the design can be checked without a screen grab

    /// Renders the HUD at one moment of a state. The blur material is approximated with a
    /// solid fill; the orb, the label and the box geometry use the real drawing path.
    static func render(state: HudState, t: TimeInterval, text: String, colour: NSColor,
                       spin: Float = 1.1, scale: CGFloat = 2) -> NSImage {
        let geometry = HudLifecycle.geometry(state, t, target: HudLifecycle.pillSize(for: text))
        let size = geometry.box
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        let image = NSImage(size: pixels)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.scaleBy(x: scale, y: scale)
            ctx.setShouldAntialias(true)
            let rect = CGRect(origin: .zero, size: size)
            let path = CGPath(roundedRect: rect, cornerWidth: geometry.radius,
                              cornerHeight: geometry.radius, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.94).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()

            let view = HudContentView(frame: rect)
            view.geometry = geometry
            view.label = text
            view.labelColour = colour
            view.spin = spin
            view.drawContents(in: ctx)
        }
        image.unlockFocus()
        return image
    }
}

/// Draws the orb and its label on top of the blur.
final class HudContentView: NSView {
    var geometry: HudGeometry?
    var label = "…"
    var labelColour: NSColor = .white
    var spin: Float = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawContents(in: ctx)
    }

    func drawContents(in ctx: CGContext) {
        guard let geometry else { return }
        let bounds = self.bounds
        let font = NSFont.systemFont(ofSize: geometry.labelSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: labelColour]
        let textSize = (label as NSString).size(withAttributes: attributes)

        let orbSize = geometry.orbPx
        let showOrb = orbSize >= 1.5 && geometry.visual.alpha > 0.01
        let gap = showOrb ? geometry.gap : 0
        let total = (showOrb ? orbSize : 0) + gap + textSize.height
        let top = (bounds.height - total) / 2

        if showOrb {
            OrbRenderer.draw(in: ctx,
                             center: CGPoint(x: bounds.midX, y: bounds.height - top - orbSize / 2),
                             size: orbSize,
                             tint: geometry.visual.tint,
                             alpha: geometry.visual.alpha,
                             spin: spin)
        }

        let textRect = CGRect(x: bounds.midX - textSize.width / 2,
                              y: bounds.height - top - (showOrb ? orbSize + gap : 0) - textSize.height,
                              width: textSize.width, height: textSize.height)
        NSGraphicsContext.saveGraphicsState()
        ctx.setShouldAntialias(true)
        (label as NSString).draw(in: textRect, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}
