import AppKit
import XCTest
@testable import Ponte

/// Paths, notes and the hotkey: the parts that touch the outside world, kept honest by tests.
final class SupportTests: XCTestCase {

    // MARK: - Where things live

    /// The app was VoiceNote once. Its files have to follow the name, or notes and models are
    /// orphaned under a folder nobody will look in again.
    func testPathsCarryTheAppsOwnName() {
        XCTAssertEqual(AppPaths.support.lastPathComponent, "Ponte")
        XCTAssertEqual(AppPaths.models.deletingLastPathComponent().lastPathComponent, "Ponte")
        XCTAssertEqual(AppPaths.audio.deletingLastPathComponent().lastPathComponent, "Ponte")
        XCTAssertEqual(AppPaths.log.lastPathComponent, "ponte.log")
        XCTAssertEqual(AppPaths.transcripts.lastPathComponent, "Ponte")
        XCTAssertEqual(AppPaths.transcripts.deletingLastPathComponent().lastPathComponent, "Documents")
    }

    func testTimestampsAreSortableAndFilesystemSafe() throws {
        let stamp = AppPaths.stamp()
        let pattern = #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#
        XCTAssertNotNil(stamp.range(of: pattern, options: .regularExpression), stamp)
        XCTAssertFalse(stamp.contains(":"), "colons in a filename are asking for trouble")
    }

    // MARK: - Notes

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ponte-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testANoteRecordsItsFrontmatterAndTranscript() throws {
        let directory = try temporaryDirectory()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try Transcriber.save(transcript: "Ship it before lunch.",
                                       audio: nil, elapsed: 12.3, took: 0.2,
                                       engine: "parakeet-ultra", directory: directory, now: when)
        let note = try XCTUnwrap(url)
        XCTAssertTrue(note.lastPathComponent.hasPrefix("note-"), note.lastPathComponent)
        XCTAssertEqual(note.deletingLastPathComponent().path, directory.path)

        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\n"), "frontmatter comes first")
        XCTAssertTrue(text.contains("duration: 12.3s"))
        XCTAssertTrue(text.contains("transcribe_time: 0.2s"))
        XCTAssertTrue(text.contains("engine: parakeet-ultra"))
        XCTAssertTrue(text.contains("audio: (deleted after transcription)"))
        XCTAssertTrue(text.hasSuffix("Ship it before lunch."), "the transcript is the note")
    }

    func testTheRollingIndexStaysBesideItsNotes() throws {
        let directory = try temporaryDirectory()
        try Transcriber.save(transcript: "First thought.", audio: nil, elapsed: 1,
                             took: 0.1, directory: directory)
        try Transcriber.save(transcript: "Second thought.", audio: nil, elapsed: 1,
                             took: 0.1, directory: directory)
        let index = try String(contentsOf: directory.appendingPathComponent("all-notes.md"),
                               encoding: .utf8)
        XCTAssertTrue(index.contains("First thought."))
        XCTAssertTrue(index.contains("Second thought."))
        XCTAssertEqual(index.components(separatedBy: "First thought.").count - 1, 1,
                       "the index appends rather than rewriting")
    }

    func testNothingHeardMeansNoNote() throws {
        let directory = try temporaryDirectory()
        XCTAssertNil(try Transcriber.save(transcript: "", audio: nil, elapsed: 3,
                                          took: 0.1, directory: directory))
        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(written.isEmpty, "an empty transcript should leave nothing behind: \(written)")
    }

    func testNotesWithTheSameTimestampNeverReplaceEachOther() throws {
        let directory = try temporaryDirectory()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try XCTUnwrap(Transcriber.save(transcript: "First.", audio: nil, elapsed: 1,
                                                    took: 0.1, directory: directory, now: when))
        let second = try XCTUnwrap(Transcriber.save(transcript: "Second.", audio: nil, elapsed: 1,
                                                     took: 0.1, directory: directory, now: when))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(History.notes(in: directory).map(\.text).sorted(), ["First.", "Second."])
    }

    func testNoteWriteFailureIsReturnedToTheCaller() throws {
        let parent = try temporaryDirectory()
        let blocker = parent.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blocker)
        XCTAssertThrowsError(try Transcriber.save(transcript: "Keep this.", audio: nil, elapsed: 1,
                                                    took: 0.1, directory: blocker))
    }

    // MARK: - The hotkey

    func testTheDefaultHotkeyIsOptionCommandSpace() {
        XCTAssertEqual(HotKeySpec.defaultKeyCode, 49)
        XCTAssertEqual(HotKeySpec.defaultModifiers, 2304)
        XCTAssertEqual(HotKeySpec.describe(keyCode: HotKeySpec.defaultKeyCode,
                                           modifiers: HotKeySpec.defaultModifiers), "⌥⌘Space")
    }

    func testModifiersAreDescribedInApplesOrder() {
        let control = UInt32(4096), option = UInt32(2048), shift = UInt32(512), command = UInt32(256)
        XCTAssertEqual(HotKeySpec.describe(keyCode: 2, modifiers: control | option), "⌃⌥D")
        XCTAssertEqual(HotKeySpec.describe(keyCode: 2, modifiers: command | shift | option),
                       "⌥⇧⌘D")
        XCTAssertEqual(HotKeySpec.describe(keyCode: 49, modifiers: control), "⌃Space")
    }

    func testKeyNamesCoverTheDocumentedSetAndAdmitWhenTheyDoNot() {
        XCTAssertEqual(HotKeySpec.name(for: 49), "Space")
        XCTAssertEqual(HotKeySpec.name(for: 9), "V")
        XCTAssertEqual(HotKeySpec.name(for: 15), "R")
        XCTAssertEqual(HotKeySpec.name(for: 122), "F1")
        XCTAssertEqual(HotKeySpec.name(for: 199), "key199", "an unknown key still says something")
    }

    // MARK: - Speech models
    //
    // A test here used to round-trip engine names, because `engine` was a stored setting with two values.
    // whisper.cpp was removed and the engine dimension with it, so what is worth asserting is that the model
    // names are distinct and that a stored one loads back as itself.

    func testParakeetModelsAreLabelled() {
        for model in ParakeetModel.allCases {
            XCTAssertEqual(ParakeetModel(rawValue: model.rawValue), model,
                           "a stored model name must load back as itself")
            XCTAssertFalse(model.shortLabel.isEmpty)
        }
        XCTAssertEqual(ParakeetModel.allCases.count, 4, "ultra, v3, v2, redux")
        XCTAssertNotEqual(ParakeetModel.ultra.shortLabel, ParakeetModel.v3.shortLabel)
    }
}
