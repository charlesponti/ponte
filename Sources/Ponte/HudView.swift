import AppKit
import SwiftUI
import WaveformCore
import WaveformUI

/// What the HUD is showing, and what its orb is drawn from.
///
/// The columns and the clock belong to the recording engine (`WaveformCapture`), so the orb Ponte
/// draws is the same picture Thames draws from the same analysis.
final class HudModel: ObservableObject {
    @Published var state: HudState = .idle
    @Published var startedAt = Date()
    @Published var label = "…"
    @Published var labelColour = Color.white.opacity(0.55)
    /// A warning from the input watcher, shown in place of the clock while it applies.
    @Published var hint: String?
    /// The box the collapse is heading for: the measured pill, text plus padding.
    @Published var target = CGSize(width: HudSpec.fullBox, height: HudSpec.fullBox)

    var ring = ColumnRing(capacity: 8192)
    var clock: StreamClock?
    var columnsPerSecond = HudSpec.columnsPerSecond
    var gain = HudSpec.orbGain
    var spinRate = HudSpec.baseSpin
}

/// The HUD at one moment in time. Pure in `t`, so a test or the CLI can render any frame of it and a
/// still of the lifecycle says something true.
struct HudBox: View {
    var state: HudState
    var t: TimeInterval
    var label: String
    var labelColour: Color
    /// Set while the input watcher has something to say; takes the label's place until it does not.
    var hint: String?
    var target: CGSize
    var ring: ColumnRing
    var clock: StreamClock?
    var columnsPerSecond: Double = HudSpec.columnsPerSecond
    var gain: Float = HudSpec.orbGain
    var spinRate: Float = HudSpec.baseSpin
    /// Off for a still: a turning orb is drawn from the wall clock, so two renders differ.
    var turning: Bool = true

    var body: some View {
        let geometry = HudLifecycle.geometry(state, t, target: target)
        let visual = geometry.visual
        let orbSize = HudSpec.orbSize * visual.orb
        let showOrb = orbSize >= 1.5 && visual.alpha > 0.01
        // While recording the label is the clock, counted from the same tick that draws the frame. A
        // warning from the input watcher takes its place, in amber, until the input comes back or the
        // take ends — the clock is not lost, it is just not the most useful thing to show.
        let text = hint ?? (state == .recording ? HudLifecycle.clock(t) : label)
        let textColour = hint == nil ? labelColour : Color(nsColor: HudSpec.amber)

        ZStack {
            RoundedRectangle(cornerRadius: geometry.radius, style: .continuous)
                .fill(Color(nsColor: HudSpec.boxFill))
                .overlay(
                    RoundedRectangle(cornerRadius: geometry.radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(HudSpec.boxBorderAlpha), lineWidth: 1))

            VStack(spacing: showOrb ? geometry.gap : 0) {
                if showOrb {
                    OrbView(
                        ring: ring, columnsPerSecond: columnsPerSecond, clock: clock,
                        scale: .decibels(floor: HudSpec.voiceFloor), gain: gain,
                        historySeconds: HudSpec.voiceHistory, showStats: false, turning: turning,
                        tint: Color(nsColor: visual.tint), dotCount: HudSpec.orbDots,
                        spinRate: spinRate, dotScale: HudSpec.orbDotScale)
                        .frame(width: HudSpec.orbSize, height: HudSpec.orbSize)
                        .scaleEffect(CGFloat(visual.orb))
                        .frame(width: orbSize, height: orbSize)
                        .opacity(visual.alpha)
                }
                Text(text)
                    .font(.system(size: geometry.labelSize, weight: .semibold))
                    .foregroundStyle(textColour)
                    .fixedSize()
            }
            .fixedSize()
        }
        .frame(width: geometry.box.width, height: geometry.box.height)
        .opacity(geometry.hudAlpha)
    }
}

/// The live HUD: the same box, ticking on SwiftUI's clock, sitting at the bottom of its panel.
struct HudView: View {
    @ObservedObject var model: HudModel

    var body: some View {
        TimelineView(.animation) { timeline in
            HudBox(
                state: model.state, t: timeline.date.timeIntervalSince(model.startedAt),
                label: model.label, labelColour: model.labelColour, hint: model.hint,
                target: model.target,
                ring: model.ring, clock: model.clock, columnsPerSecond: model.columnsPerSecond,
                gain: model.gain, spinRate: model.spinRate)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}
