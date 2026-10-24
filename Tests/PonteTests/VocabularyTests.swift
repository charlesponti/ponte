import XCTest
@testable import Ponte

/// The replacement list: the words an engine keeps getting wrong.
///
/// The point of these is that a wrong list must never cost anybody their words, and that a right one must not
/// mangle the sentence around it.
final class VocabularyTests: XCTestCase {

    private func vocab(_ pairs: [(String, String)]) -> Vocabulary {
        Vocabulary(rules: pairs.map { Vocabulary.Rule(from: $0.0, to: $0.1) })
    }

    func testAWordIsReplaced() {
        XCTAssertEqual(vocab([("parakeet", "Parakeet")]).applied(to: "we use parakeet for this"),
                       "we use Parakeet for this")
    }

    func testMatchingIgnoresCase() {
        // The engine's spelling varies, so the rule must catch every case of it.
        let v = vocab([("parakeet", "Parakeet")])
        XCTAssertEqual(v.applied(to: "Parakeet and parakeet and PARAKEET"),
                       "Parakeet and Parakeet and Parakeet")
    }

    func testOnlyWholeWordsAreReplaced() {
        // "ponte" must not fire inside "pontes" or "pontefract".
        let v = vocab([("ponte", "Ponte")])
        XCTAssertEqual(v.applied(to: "pontes and pontefract and ponte"),
                       "pontes and pontefract and Ponte")
    }

    func testAPhraseIsReplaced() {
        XCTAssertEqual(vocab([("pin to", "Ponte")]).applied(to: "I said pin to, not pinto"),
                       "I said Ponte, not pinto")
    }

    func testTheLongerPhraseWins() {
        // File order is reversed on purpose: length decides, not position, or the shorter rule eats the phrase.
        let v = vocab([("ponte", "P"), ("ponte app", "PonteApp")])
        XCTAssertEqual(v.applied(to: "the ponte app and ponte"), "the PonteApp and P")
    }

    func testTheReplacementIsLiteral() {
        // A `$` or a backslash in a name is a character, not a template directive.
        XCTAssertEqual(vocab([("c dollar", "$1\\n")]).applied(to: "c dollar"), "$1\\n")
    }

    func testNoRulesLeavesTheTextAlone() {
        XCTAssertEqual(Vocabulary().applied(to: "nothing to do here"), "nothing to do here")
    }

    func testAnUnreadableListMeansNoReplacements() throws {
        // Half-written by an editor, or a stray character: no rules, and the dictation is untouched. A broken list
        // must never cost somebody their words.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[ { \"from\": \"ponte\", ".utf8).write(to: url)
        XCTAssertEqual(Vocabulary.load(from: url).applied(to: "ponte"), "ponte")
        XCTAssertEqual(Vocabulary.load(from: url).rules.count, 0)
    }

    func testAValidListIsRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[{\"from\":\"pin to\",\"to\":\"Ponte\"}]".utf8).write(to: url)
        XCTAssertEqual(Vocabulary.load(from: url).applied(to: "pin to"), "Ponte")
    }

    func testTheFirstFileHasSomethingInItToEdit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(Vocabulary.ensureFile(at: url), url)
        XCTAssertFalse(Vocabulary.load(from: url).rules.isEmpty,
                       "a first-time file should show what a rule looks like")
        XCTAssertFalse(Vocabulary.ensureFile(at: url).path.isEmpty)
        // And it must not overwrite an existing list.
        try Data("[]".utf8).write(to: url)
        Vocabulary.ensureFile(at: url)
        XCTAssertEqual(Vocabulary.load(from: url).rules.count, 0, "an existing list must be left alone")
    }
}
