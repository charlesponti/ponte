import Foundation

/// The dictations already written to disk, read back.
///
/// There is no database and no index here on purpose. Every dictation is a markdown note in `~/Documents/Ponte`
/// with its metadata in frontmatter, so the history is a directory listing away: the files are the store, they can
/// be edited or searched with anything, and losing this window loses nothing. What it adds is finding one.
///
/// A note that cannot be read is skipped rather than breaking the list — a half-written file, or one a person
/// edited by hand, must not make the history empty.
enum History {
    struct Note: Identifiable, Equatable {
        let url: URL
        let date: Date?
        let duration: String
        let engine: String
        let audioName: String?
        let text: String

        var id: URL { url }
        var title: String { text.split(separator: "\n").first.map(String.init) ?? "(empty)" }
        /// Where the audio for this take lives, if it was kept.
        var audioURL: URL? { audioName.map { AppPaths.audio.appendingPathComponent($0) } }
        var hasAudio: Bool {
            guard let url = audioURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }

        /// Whether a search finds this note. Everything on screen is searched, not just the text: "parakeet" should
        /// find the takes that engine transcribed, and "24-10" the ones from a day.
        func matches(_ query: String) -> Bool {
            let needle = query.trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { return true }
            let haystack = [text, engine, duration, date.map { Self.stamp.string(from: $0) } ?? ""]
                .joined(separator: " ")
            return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        static let stamp: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f
        }()
    }

    /// Every note in the directory, newest first. The rolling `all-notes.md` log is not a note and is skipped by
    /// matching only files named `note-*`.
    static func notes(in directory: URL = AppPaths.transcripts) -> [Note] {
        let fm = FileManager.default
        guard let listing = try? fm.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) else { return [] }
        var found: [Note] = []
        for url in listing where url.lastPathComponent.hasPrefix("note-") && url.pathExtension == "md" {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            found.append(note(contents, at: url))
        }
        return found.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Parse one note. Frontmatter is `key: value` between the first pair of `---` fences; anything after is the
    /// transcript, kept exactly as written.
    static func note(_ contents: String, at url: URL) -> Note {
        var fields: [String: String] = [:]
        var body = contents
        let lines = contents.components(separatedBy: "\n")
        if let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
           let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[(open + 1)..<close] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[line[..<colon].trimmingCharacters(in: .whitespaces)] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let audio = fields["audio"].flatMap { $0.hasPrefix("(") ? nil : $0 }
        return Note(url: url,
                    date: fields["date"].flatMap { ISO8601DateFormatter().date(from: $0) },
                    duration: fields["duration"] ?? "",
                    engine: fields["engine"] ?? "",
                    audioName: audio,
                    text: body)
    }
}
