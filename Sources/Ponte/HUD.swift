import AppKit
import SwiftUI
import WaveformCore

/// The floating HUD: a borderless panel hosting the SwiftUI box.
///
/// The panel is one fixed size, big enough for the longest pill, with the box at its bottom centre —
/// so the box still sinks as it collapses, but without asking the window server for a new frame sixty
/// times a second. The drawing is SwiftUI, and the orb is `WaveformUI`'s, so Ponte shows the same
/// sphere Thames shows.
final class HUD {
    private var panel: NSPanel?
    private var hosting: NSHostingView<HudView>?
    private let model = HudModel()
    private var hideWork: DispatchWorkItem?

    /// Wide enough for the longest thing the HUD says ("Microphone access denied — System Settings…").
    private let panelSize = CGSize(width: 420, height: 132)
    private let bottomInset: CGFloat = 96
    private let labelDim = Color.white.opacity(0.55)

    // MARK: - Public

    /// The recording to draw from: the engine's columns, its clock, and how fast columns arrive.
    func use(columns: ColumnRing, clock: StreamClock?, columnsPerSecond: Double) {
        model.ring = columns
        model.clock = clock
        model.columnsPerSecond = columnsPerSecond
    }

    func beginRecording() {
        model.spinRate = HudSpec.baseSpin * HudSpec.recordingSpinMultiple
        set(state: .recording, text: HudLifecycle.clock(0), colour: labelDim)
    }

    /// Working: the orb turns at the model's calm rate, label is an ellipsis.
    func showWorking() {
        model.spinRate = HudSpec.workingSpin
        set(state: .working, text: "…", colour: labelDim)
    }

    /// A long operation with one number worth showing: the orb plus a percentage.
    func showDownload(percent: Int) {
        model.spinRate = HudSpec.workingSpin
        set(state: .working, text: "\(percent)%", colour: labelDim)
    }

    func showDone(_ text: String) {
        set(state: .done, text: text, colour: Color(nsColor: HudSpec.green))
    }

    func showError(_ text: String) {
        set(state: .error, text: text, colour: Color(nsColor: HudSpec.red))
    }

    /// Esc, while a dictation is in flight. One fact, and it is not a success: nothing was pasted.
    func showCancelled() {
        set(state: .cancelled, text: "Cancelled", colour: Color(nsColor: HudSpec.grey))
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
    }

    // MARK: - State machine

    private func set(state newState: HudState, text: String, colour: Color) {
        hideWork?.cancel()
        hideWork = nil
        model.state = newState
        model.startedAt = Date()
        model.label = text
        model.labelColour = colour
        model.target = HudLifecycle.pillSize(for: text)

        ensurePanel()
        panel?.orderFrontRegardless()

        if let life = HudLifecycle.lifetime(newState) {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + life, execute: work)
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        // The box draws its own edge; a panel shadow would ring the whole (mostly empty) panel.
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView: HudView(model: model))
        host.frame = NSRect(origin: .zero, size: panelSize)
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: (visible.midX - panelSize.width / 2).rounded(),
                                     y: (visible.minY + bottomInset).rounded()))
        }

        panel = p
        hosting = host
    }
}
