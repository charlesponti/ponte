import XCTest
@testable import Ponte

/// The history is a directory listing, so these test the contract between what the app writes and what the window
/// reads back — using the real writer rather than a fixture, so the two cannot drift.
final class HistoryTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ponte-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func write(_ text: String, seconds: Double = 3.2, engine: String = "parakeet-ultra",
                       at when: TimeInterval = 1_700_000_000) throws -> URL? {
        try Transcriber.save(transcript: text, audio: nil, elapsed: seconds, took: 0.2, engine: engine,
                             directory: directory, now: Date(timeIntervalSince1970: when))
    }

    func testANoteTheAppWroteReadsBack() throws {
        try write("the quick brown fox")
        let notes = History.notes(in: directory)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].text, "the quick brown fox")
        XCTAssertEqual(notes[0].engine, "parakeet-ultra")
        XCTAssertEqual(notes[0].duration, "3.2s")
        XCTAssertNotNil(notes[0].date, "the frontmatter date must parse")
        XCTAssertNil(notes[0].audioName, "audio deleted after transcription is not an audio file")
    }

    func testNewestFirst() throws {
        try write("older", at: 1_700_000_000)
        try write("newer", at: 1_700_000_600)
        XCTAssertEqual(History.notes(in: directory).map(\.text), ["newer", "older"])
    }

    func testTheRollingLogIsNotANote() throws {
        try write("one")
        try write("two", at: 1_700_000_600)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("all-notes.md").path),
            "the writer also keeps a rolling log")
        XCTAssertEqual(History.notes(in: directory).count, 2, "only note-*.md files are notes")
    }

    func testSearchCoversTheTextTheEngineAndTheDate() throws {
        try write("deploy the parser", engine: "parakeet-ultra")
        try write("something else entirely", engine: "parakeet-tdt-v3", at: 1_700_000_000 + 86_400)
        let notes = History.notes(in: directory)

        XCTAssertEqual(notes.filter { $0.matches("parser") }.count, 1)
        XCTAssertEqual(notes.filter { $0.matches("PARSER") }.count, 1, "search is case-insensitive")
        XCTAssertEqual(notes.filter { $0.matches("tdt-v3") }.count, 1, "the engine is searchable")
        XCTAssertEqual(notes.filter { $0.matches("2023-11-14") }.count, 1, "so is the day")
        XCTAssertEqual(notes.filter { $0.matches("") }.count, 2, "an empty search finds everything")
        XCTAssertEqual(notes.filter { $0.matches("   ") }.count, 2, "and so does whitespace")
        XCTAssertEqual(notes.filter { $0.matches("nothing here") }.count, 0)
    }

    func testANoteEditedByHandStillReads() throws {
        // No frontmatter at all: the whole file is the transcript, which is a perfectly reasonable thing to have
        // done to a note.
        let url = directory.appendingPathComponent("note-hand-edited.md")
        try "just some words\non two lines".write(to: url, atomically: true, encoding: .utf8)
        let notes = History.notes(in: directory)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].text, "just some words\non two lines")
        XCTAssertNil(notes[0].date)
        XCTAssertEqual(notes[0].title, "just some words")
    }

    func testAnEmptyDirectoryIsAnEmptyHistory() {
        XCTAssertTrue(History.notes(in: directory).isEmpty)
        XCTAssertTrue(History.notes(in: directory.appendingPathComponent("does-not-exist")).isEmpty,
                      "a missing folder is not a crash")
    }

    func testADeletedAudioFieldIsNotOffered() {
        // What the writer puts in when the audio was cleaned up, and what it puts in when it was kept.
        let deleted = History.note("""
        ---
        date: 2023-11-14T22:13:20Z
        duration: 2.0s
        audio: (deleted after transcription)
        ---

        words
        """, at: directory.appendingPathComponent("note-a.md"))
        XCTAssertNil(deleted.audioName)
        XCTAssertFalse(deleted.hasAudio)

        let kept = History.note("""
        ---
        date: 2023-11-14T22:13:20Z
        duration: 2.0s
        audio: rec-2023-11-14_22-13-20.wav
        ---

        words
        """, at: directory.appendingPathComponent("note-b.md"))
        XCTAssertEqual(kept.audioName, "rec-2023-11-14_22-13-20.wav")
        XCTAssertEqual(kept.audioURL?.lastPathComponent, "rec-2023-11-14_22-13-20.wav")
    }
}
