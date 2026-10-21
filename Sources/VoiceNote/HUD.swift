import AppKit

/// A small always-on-top pill that shows the live mic level while you talk,
/// then the transcription state once you stop.
final class HUD {
    enum State {
        case recording
        case working(String)
        case done(String)
        case error(String)
    }

    private var panel: NSPanel?
    private var levelView: LevelView?
    private var label: NSTextField?
    private var dot: NSView?
    private var ticker: Timer?
    private var startedAt = Date()
    private var hideWork: DispatchWorkItem?
    private var mode: State = .recording

    private let size = NSSize(width: 340, height: 92)

    // MARK: Public

    func beginRecording() {
        mode = .recording
        startedAt = Date()
        ensurePanel()
        levelView?.mode = .level
        levelView?.reset()
        dot?.layer?.backgroundColor = NSColor.systemRed.cgColor
        show()
        startTicker()
        updateLabel()
    }

    func pushLevel(_ value: Float) {
        guard case .recording = mode else { return }
        levelView?.push(value)
    }

    func showWorking(_ text: String = "Transcribing…") {
        mode = .working(text)
        levelView?.mode = .sweep
        dot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
        show()
        startTicker()
        updateLabel()
    }

    func showDone(_ text: String) {
        mode = .done(text)
        levelView?.mode = .idle
        dot?.layer?.backgroundColor = NSColor.systemGreen.cgColor
        show()
        updateLabel()
        scheduleHide(after: 1.4)
    }

    func showError(_ text: String) {
        mode = .error(text)
        levelView?.mode = .idle
        dot?.layer?.backgroundColor = NSColor.systemRed.cgColor
        show()
        updateLabel()
        scheduleHide(after: 3.0)
    }

    func hide() {
        ticker?.invalidate()
        ticker = nil
        panel?.orderOut(nil)
    }

    // MARK: Internals

    private func ensurePanel() {
        guard panel == nil else { return }

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
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

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.cornerRadius = 20
        root.layer?.masksToBounds = true

        let blur = NSVisualEffectView(frame: root.bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        root.addSubview(blur)

        // status dot
        let d = NSView(frame: NSRect(x: 20, y: size.height - 34, width: 12, height: 12))
        d.wantsLayer = true
        d.layer?.cornerRadius = 6
        d.layer?.backgroundColor = NSColor.systemRed.cgColor
        root.addSubview(d)
        dot = d

        let l = NSTextField(labelWithString: "Recording")
        l.frame = NSRect(x: 40, y: size.height - 38, width: size.width - 60, height: 20)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .labelColor
        root.addSubview(l)
        label = l

        let lv = LevelView(frame: NSRect(x: 20, y: 16, width: size.width - 40, height: 30))
        root.addSubview(lv)
        levelView = lv

        panel = p
        p.contentView = root
        positionPanel()
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - size.width / 2
        let y = visible.minY + 96
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }

    private func show() {
        guard let panel else { return }
        hideWork?.cancel()
        hideWork = nil
        positionPanel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.levelView?.tick()
            self.updateLabel()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func updateLabel() {
        switch mode {
        case .recording:
            let e = Date().timeIntervalSince(startedAt)
            label?.stringValue = String(format: "Recording  %d:%02d", Int(e) / 60, Int(e) % 60)
            label?.textColor = .labelColor
        case .working(let s):
            label?.stringValue = s
            label?.textColor = .labelColor
        case .done(let s):
            label?.stringValue = s
            label?.textColor = .systemGreen
        case .error(let s):
            label?.stringValue = s
            label?.textColor = .systemRed
        }
    }

    private func scheduleHide(after: TimeInterval) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }
}

// MARK: - Level meter

final class LevelView: NSView {
    enum Mode { case idle, level, sweep }
    var mode: Mode = .level {
        didSet { needsDisplay = true }
    }

    private var values = [Float](repeating: 0, count: 40)
    private var phase: CGFloat = 0

    func reset() {
        values = [Float](repeating: 0, count: 40)
        needsDisplay = true
    }

    func push(_ v: Float) {
        values.removeFirst()
        values.append(max(0, min(1, v)))
        needsDisplay = true
    }

    func tick() {
        phase += 0.14
        if mode == .sweep { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let n = values.count
        let gap: CGFloat = 3
        let w = max(1, (bounds.width - CGFloat(n - 1) * gap) / CGFloat(n))
        let radius = w / 2

        for i in 0..<n {
            let v: CGFloat
            switch mode {
            case .level:
                v = CGFloat(values[i])
            case .sweep:
                let s = abs(sin(Double(phase) * 0.8 + Double(i) * 0.22))
                v = 0.12 + 0.55 * CGFloat(s)
            case .idle:
                v = 0.06
            }
            let h = max(3, bounds.height * v)
            let rect = NSRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            colour(for: v).setFill()
            path.fill()
        }
    }

    private func colour(for v: CGFloat) -> NSColor {
        switch mode {
        case .level:
            // hot signal → red, normal speech → green/yellow
            let hue = 0.33 * (1 - min(1, v * 1.25))
            return NSColor(hue: hue, saturation: 0.72, brightness: 0.95, alpha: 1)
        case .sweep:
            return NSColor(srgbRed: 1.0, green: 0.68, blue: 0.15, alpha: 0.9)
        case .idle:
            return NSColor.white.withAlphaComponent(0.35)
        }
    }
}
