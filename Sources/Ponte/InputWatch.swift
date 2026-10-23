import Foundation
import WaveformCore

/// Watching the input while someone dictates, so that a take which is going to produce nothing says so
/// while there is still time to do something about it.
///
/// Why this exists, measured on the machine it was built on: of 26 recordings, 7 captured pure silence —
/// the default input was an asleep device, peaking at or below −39 dBFS. The app only ever mentioned it
/// afterwards, by which point the attempt was already lost. So this warns while there is still time.
///
/// There is deliberately **no "too quiet" warning**. An earlier version had one at −20 dBFS and it was
/// wrong: a live test that transcribed 64 characters and pasted them perfectly peaked at −30 dBFS and
/// was nagged about anyway. The two genuinely unusable recordings had peaks of −22.5 and −24.1, so no
/// threshold separates "faint but fine" from "faint and lost" — level alone cannot know, and the only
/// thing that can is whether the engine produces text, which is known too late to warn about. A warning
/// that fires on work that succeeds is worse than no warning at all.
struct InputWatch {
    /// An input with no signal in it — asleep, muted, or the wrong device — sits below this. The seven
    /// silence cases peaked between −91 and −39 dBFS, so this is 3 dB above the loudest of them and 6 dB
    /// below a quiet voice that transcribed perfectly (−30 dBFS).
    static let noSignalPeakDB: Float = -36
    /// Long enough that a person clearing their throat has had their chance.
    static let verdictAfter: TimeInterval = 3.0
    /// Anything quieter than this counts as no signal at all.
    static let silenceFloorDB: Float = -120

    enum Verdict: String, Equatable {
        case listening
        case noSignal

        /// Short enough to sit under the orb inside the square box; the whole story goes to the log.
        var label: String? {
            switch self {
            case .listening: return nil
            case .noSignal: return "Check the mic"
            }
        }
    }

    private(set) var verdict: Verdict = .listening
    /// The loudest peak seen since the take began.
    private(set) var loudestDB: Float = silenceFloorDB

    /// One column of the meter, and how long the take has been running. The verdict is about the take as
    /// a whole — someone pausing mid-sentence is no problem, someone who has not been heard at all in
    /// three seconds is.
    mutating func observe(peakDB: Float?, at elapsed: TimeInterval) -> Verdict {
        if let peakDB, peakDB > loudestDB { loudestDB = peakDB }
        guard elapsed >= Self.verdictAfter else {
            verdict = .listening
            return verdict
        }
        verdict = loudestDB < Self.noSignalPeakDB ? .noSignal : .listening
        return verdict
    }

    /// The dBFS of the loudest sample in a column — the same conversion `Scale.decibels` draws with.
    static func peakDB(_ column: Column) -> Float {
        let amplitude = max(abs(column.low), abs(column.high))
        return amplitude > 0 ? 20 * log10(amplitude) : silenceFloorDB
    }
}
