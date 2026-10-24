import Foundation

/// When each word of a live transcript becomes visible, and how long it takes to resolve.
///
/// The engine does not deliver words at the rate they are spoken. It transcribes everything it has heard each
/// time it is polled, so a burst of three or four words arrives together every ~1.2 s. Animating the burst
/// animates the wrong thing: you would see the transcript arrive in lumps, which is a property of polling rather
/// than of speech. This releases the queue at the rate the words were actually spoken — words ÷ seconds of
/// audio, both of which the engine already knows — so a slow speaker gets slow words and a fast one keeps up.
///
/// The blur is then derived rather than chosen. A word's entrance should occupy about two thirds of its slot:
/// less and consecutive words read as simultaneous, more and two of them are always mid-blur, which is a
/// permanent haze rather than a reveal.
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

    /// How much of a word's entrance has happened, for a word queued `index` slots after the first.
    static func progress(wordIndex: Int, at elapsed: Double, rate: Double) -> Double {
        let start = Double(wordIndex) * slot(rate: rate)
        let d = duration(rate: rate)
        guard elapsed > start else { return 0 }
        return min(1, (elapsed - start) / d)
    }

    /// Whether a word is still provisional: within the last two to have arrived, and not fully resolved.
    /// The newest words are the ones a later snapshot can still change, so they are the ones that should look
    /// like it — a word that looks final but moves reads as a mistake, one that looks provisional reads as thinking.
    static func provisional(wordIndex: Int, of count: Int, elapsed: Double, rate: Double) -> Bool {
        let fromEnd = count - 1 - wordIndex
        guard fromEnd < 2 else { return false }
        return progress(wordIndex: wordIndex, at: elapsed, rate: rate) < 1
    }

    private static func normalise(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }
}
