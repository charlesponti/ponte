import XCTest
@testable import Ponte

@MainActor
final class HistoryModelTests: XCTestCase {
    func testCompletionIsAttachedOnlyToItsSelectedNote() {
        let model = HistoryModel()
        let first = URL(fileURLWithPath: "/tmp/first-note.md")
        let second = URL(fileURLWithPath: "/tmp/second-note.md")
        let request = model.beginRetranscription(for: first)

        model.selection = second

        XCTAssertFalse(model.acceptRetranscription("stale text", for: first,
                                                    requestID: request, seconds: 0.4))
        XCTAssertNil(model.retranscribed)
        XCTAssertNil(model.message)
    }

    func testOnlyTheLatestRequestCanUpdateTheResult() {
        let model = HistoryModel()
        let note = URL(fileURLWithPath: "/tmp/note.md")
        let stale = model.beginRetranscription(for: note)
        let latest = model.beginRetranscription(for: note)

        XCTAssertFalse(model.acceptRetranscription("older", for: note,
                                                    requestID: stale, seconds: 0.5))
        XCTAssertTrue(model.acceptRetranscription("fresh", for: note,
                                                   requestID: latest, seconds: 0.4))
        XCTAssertEqual(model.retranscribed, .init(noteID: note, text: "fresh"))
    }

    func testChangingSelectionClearsThePreviousRetake() {
        let model = HistoryModel()
        let first = URL(fileURLWithPath: "/tmp/first-note.md")
        let second = URL(fileURLWithPath: "/tmp/second-note.md")
        let request = model.beginRetranscription(for: first)
        XCTAssertTrue(model.acceptRetranscription("fresh", for: first,
                                                   requestID: request, seconds: 0.4))

        model.selection = second

        XCTAssertNil(model.retranscribed)
    }
}
