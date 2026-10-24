import AppKit
import SwiftUI
import WaveformCore
import WaveformUI

/// What the HUD is showing, and what its orb is drawn from.
///
/// The columns and the clock belong to the recording engine (`WaveformCapture`), so the orb Ponte
/// draws is the same picture Thames draws from the same analysis.
/// Everything the live transcript needs to draw itself, and nothing else. Empty until words arrive.
struct LiveText: Equatable {
    var words: [String] = []
    /// When each word was delivered, on the take's own clock. This is what stops a late pass from being paced out
    /// afterwards: a word the engine has already returned appears at once (see `TranscriptReveal`).
    var arrivals: [TimeInterval] = []
    /// Words a second, measured from the take and smoothed, so a slow speaker gets slow words.
    var rate: Double = 2.5
    var isEmpty: Bool { words.isEmpty }

    /// A word with no recorded arrival is treated as due when it was spoken, which is the pacing default.
    /// The `>= 0` matters: callers ask for the newest word, and with no words yet that index is -1, which the
    /// obvious bounds check lets through.
    func arrival(_ index: Int) -> TimeInterval {
        index >= 0 && index < arrivals.count ? arrivals[index] : 0
    }

    /// Absorb a snapshot from the engine.
    ///
    /// The settled prefix is kept, anything new — including a tail a later snapshot revised — is stamped with the
    /// moment it arrived, and the speaking rate is re-measured and smoothed. All of that is here rather than in
    /// `HUD` so the live line can be driven and measured without a window on screen.
    mutating func absorb(_ text: String, seconds: TimeInterval, at now: TimeInterval) {
        let incoming = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard !incoming.isEmpty else { return }
        let wasEmpty = words.isEmpty
        let merged = TranscriptReveal.merge(shown: words, incoming: incoming)
        if merged.words != words {
            var next = Array(arrivals.prefix(merged.stable))
            while next.count < merged.words.count { next.append(now) }
            arrivals = next
        }
        words = merged.words
        // Measured from the take, then smoothed: the rate is what paces the words, and a jump would move a word
        // that is already on screen.
        let measured = TranscriptReveal.rate(words: words.count, seconds: seconds)
        rate = wasEmpty ? measured : rate * 0.6 + measured * 0.4
    }
}

final class HudModel: ObservableObject {
    @Published var state: HudState = .idle
    @Published var startedAt = Date()
    @Published var label = "…"
    @Published var labelColour = Color.white.opacity(0.55)
    /// A warning from the input watcher, shown in place of the clock while it applies.
    @Published var hint: String?
    /// The box the collapse is heading for: the measured pill, text plus padding.
    @Published var target = CGSize(width: HudSpec.fullBox, height: HudSpec.fullBox)
    /// What the engine has heard so far, revealed at the rate it was spoken.
    @Published var live = LiveText()
    /// How long the take ended up being. The clock must stop when the recording does, not when the HUD hides.
    @Published var recordedFor: TimeInterval = 0
    /// When the take began. Not `startedAt`, which every state change resets: the reveal has to keep running while
    /// the engine finishes after you stop talking, and a clock that restarted would freeze the line.
    var takeStartedAt = Date()

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
    /// What the engine has heard so far. Only the live states have room for it.
    var live = LiveText()
    /// The take's length once it has stopped. While recording the clock follows `t`; after that it holds.
    var recordedFor: TimeInterval = 0
    /// Seconds since the take began, which does not reset when the state changes — the transcript's own clock.
    /// Nil means "the same as `t`", which is what a still of the HUD wants: at 9 s it draws the line as it would
    /// look nine seconds into a take. The live view passes the real, monotonic clock.
    var takeElapsed: TimeInterval?

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
        // The wide box has a row under the orb instead of a single centred line: the clock holds the left,
        // and the transcript fills the rest. The clock keeps its own width so a count past nine minutes does
        // not shove the text sideways.
        let wide = (state == .recording || state == .working) && geometry.collapse < 0.5
        // The clock's number stops when the take does; the transcript's own clock must not, or the last words
        // of a take would freeze half-revealed when the engine starts thinking.
        let seconds = state == .recording ? t : recordedFor
        let transcriptClock = takeElapsed ?? t
        let lineWidth = HudSpec.liveBox.width - HudSpec.boxPadding * 2 - HudSpec.clockWidth - 8

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
                if wide {
                    HStack(spacing: 8) {
                        Text(HudLifecycle.clock(seconds))
                            .font(.system(size: HudSpec.smallLabelSize, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(HudSpec.transcriptClockAlpha))
                            .frame(width: HudSpec.clockWidth, alignment: .trailing)
                        if let hint {
                            Text(hint)
                                .font(.system(size: HudSpec.transcriptSize, weight: .semibold))
                                .foregroundStyle(Color(nsColor: HudSpec.amber))
                                .fixedSize()
                        } else {
                            TranscriptLine(words: live.words, arrivals: live.arrivals,
                                           takeElapsed: transcriptClock, rate: live.rate, width: lineWidth)
                        }
                    }
                } else {
                    Text(text)
                        .font(.system(size: geometry.labelSize, weight: .semibold))
                        .foregroundStyle(textColour)
                        .fixedSize()
                }
            }
            .fixedSize()
            // The lift is what gives the text its bottom clearance without moving the orb's top edge.
            .offset(y: -HudSpec.blockLift * (1 - geometry.collapse))
        }
        .frame(width: geometry.box.width, height: geometry.box.height)
        .opacity(geometry.hudAlpha)
    }
}

/// One line of live transcript: the words the engine has heard, revealed at the rate they were spoken.
///
/// Pure in `elapsed`, like the box around it, so any frame of it can be rendered and a still says something
/// true. The reveal itself — which word appears when, and how long it takes to resolve — is
/// `TranscriptReveal`'s, derived from the take's own speaking rate rather than chosen by eye.
///
/// Nothing here animates by state change: every word's blur, rise, scale and ink is a function of the time on
/// the clock, which is why two renders of the same moment agree.
struct TranscriptLine: View {
    var words: [String]
    var arrivals: [TimeInterval]
    var takeElapsed: TimeInterval
    var rate: Double
    var width: CGFloat

    private func arrival(_ index: Int) -> TimeInterval {
        index >= 0 && index < arrivals.count ? arrivals[index] : 0
    }

    var body: some View {
        // Before the first word there is nothing to draw, and the newest index is clamped rather than left at
        // -1: asking for word -1 is how a live-but-empty line crashed the first time it was put on screen.
        let newest = max(0, words.count - 1)
        let newestProgress = TranscriptReveal.progress(wordIndex: newest, arrival: arrival(newest),
                                                       at: takeElapsed, rate: rate)
        HStack(spacing: HudSpec.transcriptWordGap) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                let p = TranscriptReveal.progress(wordIndex: index, arrival: arrival(index),
                                                  at: takeElapsed, rate: rate)
                if p > 0 {
                    let fresh = TranscriptReveal.provisional(wordIndex: index, of: words.count,
                                                             arrival: arrival(index),
                                                             at: takeElapsed, rate: rate)
                    Text(word)
                        .font(.system(size: HudSpec.transcriptSize, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(fresh ? HudSpec.transcriptFreshAlpha
                                                                  : HudSpec.transcriptInkAlpha))
                        .blur(radius: (1 - p) * HudSpec.transcriptBlur)
                        .opacity(p)
                        .offset(y: (1 - p) * HudSpec.transcriptRise)
                        .scaleEffect(HudSpec.transcriptScale + (1 - HudSpec.transcriptScale) * p)
                        .fixedSize()
                }
            }
        }
        .fixedSize()
        // The line drifts left as the newest word lands, so it floats rather than jumping. Measured from the
        // same schedule, so it needs no animation state to restart.
        .offset(x: HudSpec.transcriptGlide * CGFloat(1 - newestProgress))
        .frame(width: width, alignment: .trailing)
        .clipped()
        .overlay(alignment: .leading) {
            LinearGradient(colors: [Color(nsColor: HudSpec.boxFill).opacity(HudSpec.boxFillAlpha), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: HudSpec.transcriptFade)
                .allowsHitTesting(false)
        }
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
                gain: model.gain, spinRate: model.spinRate,
                live: model.live, recordedFor: model.recordedFor,
                takeElapsed: timeline.date.timeIntervalSince(model.takeStartedAt))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}
