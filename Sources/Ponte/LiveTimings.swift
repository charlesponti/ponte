import Foundation

/// One live pass, timed stage by stage.
///
/// "The words are late" has several possible owners: the ticker that did not fire on time, the copy of the WAV,
/// the engine, the hop to the main queue, or the reveal that deliberately paces words at the speed they were
/// spoken. One number cannot tell them apart, so every stage goes on one line per pass.
struct PassTiming {
    var index: Int
    /// How late the pass started against the schedule it set for itself.
    var tickDelay: TimeInterval
    /// Copying the WAV so far and correcting its header.
    var snapshot: TimeInterval
    /// The transcription itself.
    var engine: TimeInterval
    /// Waiting to get onto the main queue, where the HUD is drawing.
    var hop: TimeInterval
    /// Audio this pass described.
    var covered: TimeInterval
    /// Audio on disk when the pass finished. `onDisk - covered` is how far behind the voice the line is.
    var onDisk: TimeInterval
    var words: Int
    var chars: Int
    /// The last few words heard, so the log shows *what* arrived and not only how much.
    var tail: String

    /// How much speech the line has not caught up with.
    var behind: TimeInterval { max(0, onDisk - covered) }
}

/// What `LiveText.absorb` did with a snapshot, in the terms the screen cares about.
struct AbsorbReport: Equatable {
    var words: Int
    /// Words that arrived with this pass and are not yet settled.
    var fresh: Int
    /// The settled prefix that will not change again.
    var stable: Int
    var rate: Double
    /// How long the reveal takes to show the words that just arrived, at the pace they were spoken.
    var reveal: TimeInterval
}

/// Writes the live-line diagnostics, and keeps the totals the summary at the end of a take needs.
///
/// One line per pass plus one per absorb is roughly 2-5 lines a second while a take runs, and it is the only
/// way to tell an engine that is slow from a HUD that is late.
final class LiveTimings {
    private var passes = 0
    private var engineSum = 0.0
    private var engineMax = 0.0
    private var behindSum = 0.0
    private var behindMax = 0.0

    private var absorbs = 0
    private var absorbSum = 0.0
    private var absorbMax = 0.0
    private var revealSum = 0.0

    private(set) var firstWordAt: TimeInterval?

    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = vlog) {
        self.log = log
    }

    /// One pass, as it came back.
    func pass(_ timing: PassTiming) {
        passes += 1
        engineSum += timing.engine
        engineMax = max(engineMax, timing.engine)
        behindSum += timing.behind
        behindMax = max(behindMax, timing.behind)
        log(
            String(
                format:
                    "live: pass %d  late +%.0fms  snapshot %.0fms  engine %.0fms  hop %.0fms  cover %.1fs  disk %.1fs  behind %.2fs  %dw %dc  \"%@\"",
                timing.index, timing.tickDelay * 1000, timing.snapshot * 1000, timing.engine * 1000,
                timing.hop * 1000, timing.covered, timing.onDisk, timing.behind, timing.words,
                timing.chars, timing.tail))
    }

    /// One absorb into the HUD, with the cost of the main-thread work that did it.
    func absorbed(_ report: AbsorbReport, mainThread: TimeInterval) {
        absorbs += 1
        absorbSum += mainThread
        absorbMax = max(absorbMax, mainThread)
        revealSum += report.reveal
        log(
            String(
                format: "live: hud  %dw (%d fresh, %d settled)  rate %.1f w/s  absorb %.1fms  reveal %.2fs",
                report.words, report.fresh, report.stable, report.rate, mainThread * 1000, report.reveal))
    }

    /// The first words of the take, which is the number a person actually feels.
    func firstWord(at takeTime: TimeInterval) {
        guard firstWordAt == nil else { return }
        firstWordAt = takeTime
        log(String(format: "live: first word shown at %.2fs of the take", takeTime))
    }

    /// The take's totals. Returns the line rather than logging it, so `stop` decides when it lands.
    func summary(take: TimeInterval) -> String {
        let engineMean = passes > 0 ? engineSum / Double(passes) : 0
        let behindMean = passes > 0 ? behindSum / Double(passes) : 0
        let absorbMean = absorbs > 0 ? absorbSum / Double(absorbs) : 0
        let revealMean = absorbs > 0 ? revealSum / Double(absorbs) : 0
        let first = firstWordAt.map { String(format: "%.2fs", $0) } ?? "never"
        return String(
            format:
                "live: take %.1fs — %d passes · engine mean %.0fms max %.0fms · behind mean %.2fs max %.2fs · absorb mean %.1fms max %.1fms · reveal mean %.2fs · first word %@",
            take, passes, engineMean * 1000, engineMax * 1000, behindMean, behindMax, absorbMean * 1000,
            absorbMax * 1000, revealMean, first)
    }

    /// A take is over: clear the totals so the next one starts from zero.
    func reset() {
        passes = 0
        engineSum = 0
        engineMax = 0
        behindSum = 0
        behindMax = 0
        absorbs = 0
        absorbSum = 0
        absorbMax = 0
        revealSum = 0
        firstWordAt = nil
    }
}
