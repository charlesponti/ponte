import XCTest
@testable import Ponte

final class RetakeTests: XCTestCase {
    func testNoTakeMeansNothingToOffer() {
        XCTAssertNil(Retake.candidate(nil), "before any dictation there is nothing to re-run")
    }

    func testAMissingFileIsNotOffered() {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("not-here-\(UUID()).wav")
        XCTAssertNil(Retake.candidate(gone),
                     "the audio is not kept by default, so the offer has to expire with the file")
    }

    func testAnExistingTakeIsOffered() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID()).wav")
        try Data([0x00, 0x01]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(Retake.candidate(url), url)
    }

    func testNothingIsAdoptedWhileKeepAudioIsOn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retake-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0]).write(to: dir.appendingPathComponent("a.wav"))
        XCTAssertNil(Retake.launchCandidate(in: dir, keepAudio: true),
                     "with audio kept deliberately, a file here may be a take that worked")
    }

    func testTheNewestKeptTakeIsAdopted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retake-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let older = dir.appendingPathComponent("older.wav")
        let newer = dir.appendingPathComponent("newer.wav")
        try Data([0]).write(to: older)
        try Data([0]).write(to: newer)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer.path)
        // /var is /private/var: the same file, spelled differently by the directory listing.
        XCTAssertEqual(Retake.launchCandidate(in: dir, keepAudio: false)?.resolvingSymlinksInPath(),
                       newer.resolvingSymlinksInPath())
    }

    func testAnEmptyDirectoryAdoptsNothing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retake-\(UUID())")
        XCTAssertNil(Retake.launchCandidate(in: dir, keepAudio: false))
    }

    func testTheTitleSaysWhatItDoes() {
        XCTAssertFalse(Retake.menuTitle.isEmpty)
        XCTAssertTrue(Retake.menuTitle.lowercased().contains("again"),
                      "the label has to read as a second attempt, not as a new one")
    }

    func testDescribeNamesTheTakeWithoutAPath() {
        let url = URL(fileURLWithPath: "/Users/someone/Library/audio/rec-2026-10-24.wav")
        XCTAssertEqual(Retake.describe(url), "rec-2026-10-24.wav")
    }
}