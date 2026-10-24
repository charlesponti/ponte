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

    func testAWordIsInvisibleBeforeItsSlotAndDoneAfterIt() {
        let rate = 2.5                        // slot 0.4, duration 0.288
        XCTAssertEqual(TranscriptReveal.progress(wordIndex: 3, at: 1.19, rate: rate), 0, accuracy: 1e-9)
        XCTAssertEqual(TranscriptReveal.progress(wordIndex: 3, at: 1.2, rate: rate), 0, accuracy: 1e-9)
        XCTAssertEqual(TranscriptReveal.progress(wordIndex: 3, at: 1.344, rate: rate), 0.5, accuracy: 1e-6)
        XCTAssertEqual(TranscriptReveal.progress(wordIndex: 3, at: 1.488, rate: rate), 1, accuracy: 1e-9)
        XCTAssertEqual(TranscriptReveal.progress(wordIndex: 3, at: 9.0, rate: rate), 1, accuracy: 1e-9)
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
        // Words 3 and 4 start at 1.2 s and 1.6 s; at 1.35 s the fourth has not begun and the third is halfway.
        XCTAssertTrue(TranscriptReveal.provisional(wordIndex: 4, of: 5, elapsed: 1.35, rate: rate))
        XCTAssertTrue(TranscriptReveal.provisional(wordIndex: 3, of: 5, elapsed: 1.35, rate: rate))
        XCTAssertFalse(TranscriptReveal.provisional(wordIndex: 2, of: 5, elapsed: 1.35, rate: rate),
                       "a word three from the end is confirmed by then")
        XCTAssertFalse(TranscriptReveal.provisional(wordIndex: 4, of: 5, elapsed: 3.0, rate: rate),
                       "once a later snapshot agrees, the word settles")
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
