import XCTest
@testable import Ponte

/// The day grouping behind the ledger, and the numbers it prints in a header.
///
/// These are the parts of the composition that are arithmetic rather than taste: which day a take belongs to, what a
/// header says, and how a stored "13.9s" becomes a total. Worth pinning down, because a wrong total would be a lie in
/// a quiet place where nobody looks for one.
final class DaySectionTests: XCTestCase {

    private func note(_ day: Date, _ duration: String, _ text: String = "a sentence") -> History.Note {
        History.Note(url: URL(fileURLWithPath: "/tmp/note-\(day.timeIntervalSince1970).md"),
                     date: day, duration: duration, engine: "parakeet-ultra",
                     audioName: nil, text: text)
    }

    func testDurationsParseFromTheStoredForm() {
        XCTAssertEqual(DaySection.seconds(of: note(Date(), "13.9s")), 13.9, accuracy: 0.001)
        XCTAssertEqual(DaySection.seconds(of: note(Date(), " 4.5s ")), 4.5, accuracy: 0.001)
        XCTAssertEqual(DaySection.seconds(of: note(Date(), "")), 0)
        XCTAssertEqual(DaySection.seconds(of: note(Date(), "unknown")), 0, "anything odd counts as zero, never a crash")
    }

    func testATakeLandsInItsOwnDay() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let sections = DaySection.group([
            note(today.addingTimeInterval(3600), "2.0s"),
            note(yesterday.addingTimeInterval(3600), "3.0s"),
        ])

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].title, "Today")
        XCTAssertEqual(sections[1].title, "Yesterday")
        XCTAssertEqual(sections[0].count, 1)
    }

    func testOrderIsPreservedNewestFirst() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!

        let sections = DaySection.group([
            note(today.addingTimeInterval(600), "1.0s"),
            note(twoDaysAgo.addingTimeInterval(600), "1.0s"),
        ])

        XCTAssertEqual(sections.map(\.title), ["Today", DateFormatter.ledgerDay.string(from: twoDaysAgo)])
        XCTAssertEqual(sections.map(\.id), sections.map(\.id).sorted(by: >), "newest day first")
    }

    func testTheHeaderTotalsAreReal() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let sections = DaySection.group([
            note(today.addingTimeInterval(600), "13.9s"),
            note(today.addingTimeInterval(900), "4.5s"),
        ])

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].count, 2)
        XCTAssertEqual(sections[0].seconds, 18.4, accuracy: 0.001)
        XCTAssertEqual(sections[0].summary, "2 dictations · 18 s")
    }

    func testDurationReadsInTheUnitThatFits() {
        XCTAssertEqual(DaySection.duration(18.4), "18 s")
        XCTAssertEqual(DaySection.duration(90), "1 m 30 s")
        XCTAssertEqual(DaySection.duration(3600 + 120), "1 h 2 m")
    }

    func testASingleTakeIsNotPluralised() {
        let today = Calendar.current.startOfDay(for: Date())
        let sections = DaySection.group([note(today.addingTimeInterval(60), "1.0s")])
        XCTAssertEqual(sections[0].summary, "1 dictation · 1 s")
    }

    func testAMissingDateDoesNotBreakGrouping() {
        let sections = DaySection.group([note(Date.distantPast, "1.0s")])
        XCTAssertEqual(sections.count, 1, "an undated note still has to appear somewhere")
    }
}

private extension DateFormatter {
    static let ledgerDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM"
        return f
    }()
}
