import XCTest
@testable import Ponte

final class TranscriptRevealTests: XCTestCase {

    // MARK: - The derivation

    func testTheDefaultIsDerivedNotChosen() {
        // Conversational English is about 150 words a minute: 2.5 a second, a 400 ms slot, and two thirds of it.
        XCTAssertEqual(TranscriptReveal.slot(rate: 2.5), 0.4, accuracy: 1e-9)
        XCTAssertEqual(TranscriptReveal.duration(rate: 2.5), 0.288, accuracy: 1e-9)
    }

    func testDurationIsTwoThirdsOfTheSlot() {
        // The floor bites before the rule would: at 4.8 words a second, 72 % of the slot is 0.15 — the shortest
        // entrance the eye still reads as motion. So the rule holds above the floor and the floor holds above it.
        for rate in [2.0, 2.5, 3.0, 4.0] {
            let expected = 0.72 * TranscriptReveal.slot(rate: rate)
            XCTAssertEqual(TranscriptReveal.duration(rate: rate), expected, accuracy: 1e-9,
                           "at \(rate) words a second the entrance should occupy 72 % of the slot")
        }
        for rate in [4.8, 5.0, 6.0] {
            XCTAssertEqual(TranscriptReveal.duration(rate: rate), TranscriptReveal.minDuration, accuracy: 1e-9,
                           "past 4.8 words a second the perceptual floor takes over from the rule")
        }
    }

    func testSlowSpeechIsNeverTooSlow() {
        // The floor matters more than the formula: an entrance longer than its slot leaves two words mid-blur.
        // With the rate clamped to 2, the longest duration the formula can produce is 0.36 — the 0.40 bound is
        // defensive, and deliberately unreachable while minRate is 2.
        XCTAssertEqual(TranscriptReveal.duration(rate: 2), 0.36, accuracy: 1e-9)
        XCTAssertEqual(TranscriptReveal.duration(rate: 0.5), 0.36, accuracy: 1e-9, "the rate clamps first")
        XCTAssertLessThanOrEqual(TranscriptReveal.duration(rate: 2), TranscriptReveal.maxDuration)
    }

    func testFastSpeechIsNeverACut() {
        // Below 150 ms the eye reads a cut rather than a blur, however fast somebody talks.
        XCTAssertEqual(TranscriptReveal.duration(rate: 6), TranscriptReveal.minDuration, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(TranscriptReveal.duration(rate: 6), TranscriptReveal.minDuration)
    }

    // MARK: - The measured rate

    func testTheRateIsMeasuredFromTheTake() {
        XCTAssertEqual(TranscriptReveal.rate(words: 40, seconds: 16), 2.5, accuracy: 1e-9)
        XCTAssertEqual(TranscriptReveal.rate(words: 48, seconds: 16), 3.0, accuracy: 1e-9)
    }

    func testTheRateIsClampedAtBothEnds() {
        XCTAssertEqual(TranscriptReveal.rate(words: 1, seconds: 60), TranscriptReveal.minRate)
        XCTAssertEqual(TranscriptReveal.rate(words: 300, seconds: 30), TranscriptReveal.maxRate)
        XCTAssertEqual(TranscriptReveal.rate(words: 10, seconds: 0), TranscriptReveal.minRate,
                       "a take with no duration yet cannot produce a rate")
    }

    // MARK: - The schedule

    func testAWordIsInvisibleBeforeItsMomentAndDoneAfterIt() {
        // Word 3 of a 2.5 words/second take was spoken at 1.2 s and may appear at 1.45 s — its own moment plus
        // the display latency — resolving over 0.288 s.
        let rate = 2.5
        let arrival: TimeInterval = 0                       // the engine had it all along
        XCTAssertEqual(TranscriptReveal.progress(wordIndex: 3, arrival: arrival, at: 1.44, rate: rate), 0, accuracy: 1e-9)
        XCTAssertEqual(TranscriptReveal.progress(wordIndex: 3, arrival: arrival, at: 1.45, rate: rate), 0, accuracy: 1e-9)
        XCTAssertEqual(TranscriptReveal.progress(wordIndex: 3, arrival: arrival, at: 1.594, rate: rate), 0.5, accuracy: 1e-6)
        XCTAssertEqual(TranscriptReveal.progress(wordIndex: 3, arrival: arrival, at: 1.738, rate: rate), 1, accuracy: 1e-9)
        XCTAssertEqual(TranscriptReveal.progress(wordIndex: 3, arrival: arrival, at: 9.0, rate: rate), 1, accuracy: 1e-9)
    }

    // MARK: - The complaint

    /// **A word the engine has already delivered is never held back.** This is the bug the metering introduced:
    /// the reveal was paced by word *index* from a fixed origin, so a pass that returned ten words at once left
    /// nine of them waiting behind the schedule, and they trickled out after the dictation had ended.
    func testAWordTheEngineHasDeliveredIsNeverHeldBack() {
        let rate = 2.5
        for passInterval in [0.4, 1.2, 2.5] {
            for takeTime in stride(from: 0.0, through: 12.0, by: 0.1) {
                let delivered = Int(max(0, takeTime - passInterval) * rate)
                for i in 0..<delivered {
                    let arrival = Double(i) / rate + passInterval     // this pass brought it
                    let spoken = Double(i) * TranscriptReveal.slot(rate: rate)
                    guard arrival >= spoken + TranscriptReveal.displayLatency else { continue }
                    let p = TranscriptReveal.progress(wordIndex: i, arrival: arrival, at: takeTime, rate: rate)
                    XCTAssertGreaterThan(p, 0,
                        "word \(i) arrived at \(arrival)s and was still hidden at \(takeTime)s")
                }
            }
        }
    }

    /// And the line does not keep arriving after the voice stops: at the moment a take ends, nothing is waiting.
    func testNothingDrainsAfterTheVoiceStops() {
        let rate = 2.5
        let takeSeconds = 8.0
        let spoken = Int(takeSeconds * rate)                       // 20 words said
        for passInterval in [0.4, 1.2] {
            let arrival = takeSeconds + passInterval               // the final pass lands just after the end
            for i in 0..<spoken {
                let wordArrival = min(Double(i) / rate + passInterval, arrival)
                let p = TranscriptReveal.progress(wordIndex: i, arrival: wordArrival,
                                                  at: arrival, rate: rate)
                XCTAssertGreaterThan(p, 0, "word \(i) was still waiting when the last pass landed")
            }
        }
    }

    /// The pacing still does its job for what it is for: a burst delivered *early* arrives one word at a time at
    /// the rhythm of speech, rather than all at once.
    func testABurstDeliveredEarlyIsStillSpreadOut() {
        let rate = 2.5
        // Seven words all delivered at 0.5 s, for a take that is 2.688 s of speech.
        let arrivals: TimeInterval = 0.5
        var visibleEarly = 0
        for i in 0..<7 {
            if TranscriptReveal.progress(wordIndex: i, arrival: arrivals, at: 0.6, rate: rate) > 0 { visibleEarly += 1 }
        }
        XCTAssertLessThanOrEqual(visibleEarly, 1, "at 0.6 s only the first word may be on screen")
        var visibleLate = 0
        for i in 0..<7 {
            if TranscriptReveal.progress(wordIndex: i, arrival: arrivals, at: 2.7, rate: rate) > 0 { visibleLate += 1 }
        }
        XCTAssertEqual(visibleLate, 7, "and all seven by the time the spoken moment for each has passed")
    }

    func testABurstDrainsFasterThanTheNextSnapshotArrives() {
        // The property that makes metering worth doing: seven words arriving at once — what a slow snapshot of a
        // fast speaker looks like — are all resolved within 2.7 s, well inside the interval they arrived on.
        let rate = 2.5
        let lastIndex = 6
        let finishesAt = Double(lastIndex) * TranscriptReveal.slot(rate: rate) + TranscriptReveal.duration(rate: rate)
        XCTAssertEqual(finishesAt, 2.688, accuracy: 1e-9)
        XCTAssertLessThan(finishesAt, 3.0)
    }

    func testEveryWordResolvesBeforeTheNextOneArrives() {
        for rate in [2.0, 2.5, 3.0, 4.0, 6.0] {
            let slot = TranscriptReveal.slot(rate: rate)
            let d = TranscriptReveal.duration(rate: rate)
            XCTAssertLessThanOrEqual(d, slot,
                                     "at \(rate) words a second a word must finish before the next lands")
        }
    }

    // MARK: - Provisional ink

    func testTheNewestWordsAreProvisionalUntilTheyResolve() {
        let rate = 2.5
        // Word 3 may appear at 1.45 s and word 4 at 1.85 s; at 1.6 s the fourth has not begun and the third is
        // halfway through resolving.
        let arrival: TimeInterval = 0
        XCTAssertTrue(TranscriptReveal.provisional(wordIndex: 4, of: 5, arrival: arrival, at: 1.6, rate: rate))
        XCTAssertTrue(TranscriptReveal.provisional(wordIndex: 3, of: 5, arrival: arrival, at: 1.6, rate: rate))
        XCTAssertFalse(TranscriptReveal.provisional(wordIndex: 2, of: 5, arrival: arrival, at: 1.6, rate: rate),
                       "a word three from the end is confirmed by then")
        XCTAssertFalse(TranscriptReveal.provisional(wordIndex: 4, of: 5, arrival: arrival, at: 3.0, rate: rate),
                       "once a later snapshot agrees, the word settles")
    }

    // MARK: - The complaint, as a measurement

    /// With the engine delivering words in lumps — which is what a slow pass over a growing take looks like —
    /// how long does a word wait after the engine has handed it over?
    ///
    /// The old reveal answered this with *seconds*: it paced words by index from a fixed origin, so a pass that
    /// returned a dozen words left eleven of them queued, and the line went on arriving after the dictation had
    /// ended. Now a word may wait only until the moment it was spoken, so a lump delivered late is not paced at
    /// all — it is already overdue.
    func testAWordWaitsOnlyUntilItsSpokenMoment() {
        let rate = 2.5
        var live = LiveText()
        var worst: TimeInterval = 0
        var visibleWhenLumpLanded = 0

        // Ten passes, 1.2 s apart, each returning everything heard so far: the shape of a slow poll.
        for pass in 1...10 {
            let takeTime = Double(pass) * 1.2
            let spoken = Int(takeTime * rate)
            live.absorb(Array(repeating: "word", count: spoken).enumerated()
                            .map { "w\($0.offset)" }.joined(separator: " "),
                        seconds: takeTime, at: takeTime)
            for i in 0..<live.words.count {
                let arrival = live.arrival(i)
                var t = arrival
                while TranscriptReveal.progress(wordIndex: i, arrival: arrival, at: t, rate: live.rate) == 0 {
                    t += 0.02
                }
                worst = max(worst, t - arrival)
            }
            // A hair after the lump lands: a word is drawn when takeTime is strictly past its moment, so at the
            // exact instant of arrival nothing new is on screen and this would measure the previous pass.
            visibleWhenLumpLanded = (0..<live.words.count).filter {
                TranscriptReveal.progress(wordIndex: $0, arrival: live.arrival($0),
                                          at: takeTime + 0.02, rate: live.rate) > 0
            }.count
        }

        XCTAssertLessThan(worst, 0.35,
                          "a word waited \(worst)s after the engine delivered it")
        // And at the last lump, essentially the whole transcript is on screen rather than queued.
        XCTAssertGreaterThan(visibleWhenLumpLanded, Int(10 * 1.2 * rate) - 2)
    }

    // MARK: - Merging a new snapshot

    func testAConfirmedPrefixDoesNotAnimateAgain() {
        let merged = TranscriptReveal.merge(shown: ["the", "quick", "brown", "fox"],
                                           incoming: ["the", "quick", "brown", "fox", "jumps"])
        XCTAssertEqual(merged.stable, 4, "the four settled words must not blur in a second time")
        XCTAssertEqual(merged.words, ["the", "quick", "brown", "fox", "jumps"])
    }

    func testARevisedTailIsReplacedNotAppended() {
        // This is why the merge exists: a later snapshot hears "there" where the first heard "their". Appending
        // would give "their there"; replacing from the first difference corrects it.
        let merged = TranscriptReveal.merge(shown: ["we", "put", "it", "their"],
                                           incoming: ["we", "put", "it", "there"])
        XCTAssertEqual(merged.stable, 3)
        XCTAssertEqual(merged.words, ["we", "put", "it", "there"])
    }

    func testPunctuationAndCaseDoNotCountAsARevision() {
        let merged = TranscriptReveal.merge(shown: ["the", "fox"], incoming: ["The", "fox,"])
        XCTAssertEqual(merged.stable, 2, "a comma is not a new word")
    }

    func testAShorterSnapshotDoesNotDeleteSettledWords() {
        // A snapshot can come back with less than an earlier one if the tail was cut mid-word. Settled words stay.
        let merged = TranscriptReveal.merge(shown: ["one", "two", "three"], incoming: ["one", "two"])
        XCTAssertEqual(merged.stable, 2)
        XCTAssertEqual(merged.words, ["one", "two", "three"])
    }
}
