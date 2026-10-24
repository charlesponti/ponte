import Foundation

/// When each word of a live transcript becomes visible, and how long it takes to resolve.
///
/// The engine does not deliver words at the rate they are spoken. It transcribes everything it has heard each
/// time it is polled, so a burst of words arrives together — and the longer the take, the longer a pass takes and
/// the bigger the burst. Pacing a burst out by *word index from a fixed origin* is the obvious thing and it is
/// wrong: the words pile up behind the schedule and trickle out after the dictation has ended, so you finish
/// talking and then watch your own sentence arrive.
///
/// A word's appearance is therefore the later of two moments:
///
/// - **when it was spoken** — `index ÷ rate` plus a small display latency. This is the only thing that paces a
///   word, and it exists so a burst delivered *early* is spread out at the rhythm of speech rather than landing
///   as a lump.
/// - **when it arrived** — the moment the engine actually returned it. A word delivered late is never held back
///   any further: it appears at once, which is what keeps the line level with the voice instead of behind it.
///
/// The blur is derived rather than chosen. A word's entrance should occupy about two thirds of its slot: less and
/// consecutive words read as simultaneous, more and two of them are always mid-blur, which is a permanent haze.
///
/// Pure in its inputs, like `HudLifecycle`, so the schedule can be asserted instead of watched.
enum TranscriptReveal {
    /// Words per second, clamped. Below 2 the line looks stalled; above 6 nobody reads it anyway.
    static let minRate: Double = 2
    static let maxRate: Double = 6
    /// The share of a word's slot its entrance may occupy.
    static let occupancy: Double = 0.72
    static let minDuration: Double = 0.15   // under this the eye reads a cut, not a blur
    static let maxDuration: Double = 0.40   // over this the word outlives its own slot
    /// How long after a word was spoken it appears, provided the engine already has it. Small enough to be
    /// imperceptible against the engine's own round trip, large enough that the last word of a burst does not
    /// appear before the ear has finished hearing it.
    static let displayLatency: Double = 0.25

    /// Seconds between one word arriving and the next.
    static func slot(rate: Double) -> Double { 1 / clampRate(rate) }

    /// How long a word takes to resolve: two thirds of its slot, bounded by what the eye will read as motion.
    static func duration(rate: Double) -> Double {
        min(maxDuration, max(minDuration, occupancy * slot(rate: rate)))
    }

    /// The speaking rate of a take. Both numbers come from the engine's own output, so this is measured rather
    /// than assumed: a take of 40 words over 16 seconds of audio spoke at 2.5 words a second.
    static func rate(words: Int, seconds: Double) -> Double {
        guard seconds > 0 else { return minRate }
        return clampRate(Double(words) / seconds)
    }

    static func clampRate(_ rate: Double) -> Double {
        guard rate.isFinite else { return minRate }
        return min(maxRate, max(minRate, rate))
    }

    /// The moment a word may appear: when it was spoken, or when it arrived, whichever is later.
    static func start(wordIndex: Int, arrival: TimeInterval, rate: Double) -> Double {
        max(Double(wordIndex) * slot(rate: rate) + displayLatency, arrival)
    }

    /// How much of a word's entrance has happened. Zero means it is not on screen at all.
    static func progress(wordIndex: Int, arrival: TimeInterval, at takeTime: Double, rate: Double) -> Double {
        let from = start(wordIndex: wordIndex, arrival: arrival, rate: rate)
        guard takeTime > from else { return 0 }
        return min(1, (takeTime - from) / duration(rate: rate))
    }

    /// Whether a word is still provisional: among the last two to have appeared, and not fully resolved.
    /// The newest words are the ones a later snapshot can still change, so they are the ones that should look
    /// like it — a word that looks final but moves reads as a mistake, one that looks provisional reads as thinking.
    static func provisional(wordIndex: Int, of count: Int, arrival: TimeInterval,
                            at takeTime: Double, rate: Double) -> Bool {
        guard count - 1 - wordIndex < 2 else { return false }
        return progress(wordIndex: wordIndex, arrival: arrival, at: takeTime, rate: rate) < 1
    }

    /// The words to keep showing, and where the new material starts.
    ///
    /// Each snapshot re-transcribes the audio so far, so the tail of the transcript can change: a word that came
    /// back as "there" may come back as "their". The longest shared prefix is kept — those words are settled and
    /// must not animate again — and everything after it is replaced, so a revision is corrected rather than
    /// appended to. `stable` is how many leading words are already settled.
    static func merge(shown: [String], incoming: [String]) -> (words: [String], stable: Int) {
        var shared = 0
        while shared < shown.count, shared < incoming.count,
              normalise(shown[shared]) == normalise(incoming[shared]) {
            shared += 1
        }
        // A snapshot that only drops words (a shorter tail) keeps what is settled and ignores the rest.
        if incoming.count < shown.count, shared == incoming.count { return (shown, shared) }
        return (incoming, shared)
    }

    private static func normalise(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }
}
