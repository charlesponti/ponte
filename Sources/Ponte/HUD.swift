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
        model.live = LiveText()
        model.recordedFor = 0
        model.takeStartedAt = Date()
        set(state: .recording, text: HudLifecycle.clock(0), colour: labelDim)
    }

    /// How long the take turned out to be. The clock holds here; the transcript carries on resolving whatever
    /// words the last live pass brought back, which is why this does not clear it.
    func recorded(seconds: TimeInterval) {
        model.recordedFor = seconds
    }

    /// What the engine has heard so far, from a live pass. Each snapshot re-transcribes the audio, so the tail
    /// can change: `TranscriptReveal.merge` keeps the settled prefix and replaces what follows it.
    ///
    /// `seconds` is the audio the pass ran over, which is how the speaking rate is measured rather than assumed.
    @discardableResult
    func pushTranscript(_ text: String, seconds: TimeInterval) -> AbsorbReport? {
        guard model.state == .recording || model.state == .working else { return nil }
        var live = model.live
        let report = live.absorb(text, seconds: seconds, at: Date().timeIntervalSince(model.takeStartedAt))
        model.live = live
        return report
    }

    /// The live preview has stopped on a long take: say so, then let the frozen words come back.
    func pausePreview() {
        guard model.state == .recording else { return }
        var live = model.live
        live.pausePreview(at: Date().timeIntervalSince(model.takeStartedAt))
        model.live = live
    }

    /// Working: the orb turns at the model's calm rate, label is an ellipsis.
    func showWorking() {
        model.spinRate = HudSpec.workingSpin
        set(state: .working, text: "…", colour: labelDim)
    }

    /// A wait with one number worth showing: a grey orb turning like a clock, and the percentage.
    func showDownload(percent: Int) {
        model.spinRate = HudSpec.loadingSpin
        set(state: .loading, text: "\(percent)%", colour: Color(nsColor: HudSpec.blueGrey))
    }

    func showDone(_ text: String) {
        set(state: .done, text: text, colour: Color(nsColor: HudSpec.green))
    }

    func showError(_ text: String) {
        set(state: .error, text: text, colour: Color(nsColor: HudSpec.red))
    }

    /// The first run: the model is being fetched and a dictation cannot be honoured yet. Grey and
    /// steady rather than red: this is the app doing what it said it would, not a fault.
    func showLoading(percent: Int?) {
        model.spinRate = HudSpec.loadingSpin
        set(state: .loading,
            text: percent.map { "Loading — \($0)%" } ?? "Loading",
            colour: Color(nsColor: HudSpec.blueGrey))
    }

    /// A word from the input watcher, in place of the clock while it applies. Passing nil clears it.
    /// This never changes the state: the recording carries on and the clock is still running.
    func setHint(_ text: String?) {
        guard model.hint != text else { return }
        model.hint = text
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
        // A new state makes any standing warning obsolete.
        model.hint = nil
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

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: HudSpec.panelSize),
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
        host.frame = NSRect(origin: .zero, size: HudSpec.panelSize)
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: (visible.midX - HudSpec.panelSize.width / 2).rounded(),
                                     y: (visible.minY + HudSpec.bottomInset).rounded()))
        }

        panel = p
        hosting = host
    }
}
