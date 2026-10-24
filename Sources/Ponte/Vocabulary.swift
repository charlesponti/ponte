import Foundation

/// Replacements applied after transcription: the words an engine keeps getting wrong.
///
/// The engine has its own vocabulary boosting (`CustomVocabularyContext`, which biases the decoder) and that is the
/// better mechanism where it works. This is the other half, and the one that needs nothing: no model, no download,
/// no rebuild. It fixes the cases that actually annoy people — a product name, a colleague, an acronym — because
/// those are wrong *consistently*, and a replacement is exact where a decoder's guess is not.
///
/// The list is plain JSON in Application Support, so it can be edited by hand or by anything else:
///
///     [ { "from": "parakeet", "to": "Parakeet" },
///       { "from": "pin to",   "to": "Ponte" },
///       { "from": "ponte app", "to": "the Ponte app" } ]
///
/// Matching is case-insensitive and whole-word, and longer phrases are applied before shorter ones so "ponte app"
/// can be replaced without "ponte" also firing inside it. A file that cannot be read is not an error: no
/// replacements is the correct answer for a dictation, and a broken list must never cost anyone their words.
struct Vocabulary {
    struct Rule: Codable, Equatable {
        var from: String
        var to: String
    }

    var rules: [Rule] = []

    static var fileURL: URL { AppPaths.vocabulary }

    /// Read the list. Anything unreadable — missing, malformed, half-written by an editor — yields no rules.
    static func load(from url: URL = fileURL) -> Vocabulary {
        guard let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([Rule].self, from: data) else { return Vocabulary() }
        return Vocabulary(rules: rules.filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// Write a starting file if none exists, so the menu item has something to open rather than an empty buffer.
    /// Returns the URL either way.
    @discardableResult
    static func ensureFile(at url: URL = fileURL) -> URL {
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        let sample = [
            Rule(from: "parakeet", to: "Parakeet"),
            Rule(from: "ponte", to: "Ponte"),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(sample) { try? data.write(to: url) }
        return url
    }

    /// The transcript with every rule applied.
    ///
    /// Longer phrases first is the whole of the ordering rule; within the same length the file's order is kept. The
    /// replacement is literally the rule's text — no template, so a `$` or a backslash in a name is not special.
    func applied(to text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var out = text
        for rule in rules.sorted(by: { $0.from.count > $1.from.count }) where !rule.from.isEmpty {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: rule.from) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            var result = ""
            var last = out.startIndex
            for match in re.matches(in: out, range: NSRange(out.startIndex..., in: out)) {
                guard let range = Range(match.range, in: out) else { continue }
                result += out[last..<range.lowerBound]
                result += rule.to
                last = range.upperBound
            }
            result += out[last...]
            out = result
        }
        return out
    }
}
