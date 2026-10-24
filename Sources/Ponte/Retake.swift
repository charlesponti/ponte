import AVFoundation
import Foundation

/// Whether there is a take worth transcribing a second time, and what the menu should call it.
///
/// A take that produced no text is left on disk for exactly this purpose. `Settings.keepAudio` is off by default,
/// so the file survives only until the next dictation — which makes this a window rather than a feature, and the
/// reason the menu offers the retake while the audio is still there rather than promising it always will.
///
/// Re-running is deliberately manual. It is an escape hatch, not a policy: the two takes in this project's log
/// that no engine could transcribe cleanly were *faint*, and no amount of retrying changes a recording that does
/// not contain the words. What it does rescue is a take that failed for a reason outside the audio — a model
/// still warming, a device that came up late, an engine that threw — where the file is the only record of what
/// was said and the first attempt was the thing that went wrong.
enum Retake {
    static let menuTitle = "Transcribe the last take again"

    /// The take to offer, or nil when there is nothing left to run.
    ///
    /// Checks the file rather than trusting the remembered path: Ponte's audio directory is its own, but the
    /// file can be gone — deleted by a later dictation with `keepAudio` off, or removed by hand.
    static func candidate(_ remembered: URL?) -> URL? {
        guard let url = remembered else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The take to offer after a restart, or nil.
    ///
    /// A failed take outlives the process: the audio is on disk while the app that recorded it is not, so the
    /// menu used to lose the offer even though the file was still sitting there. Reasons to adopt one:
    ///
    /// - With `keepAudio` off, *any* file in the audio directory is there because a take produced no text — that
    ///   is the only reason one is kept — so the newest is the take worth offering.
    /// - With `keepAudio` on, the directory also holds takes that succeeded, and the app cannot tell those apart
    ///   from the failures. Adopting nothing is better than guessing.
    static func launchCandidate(in directory: URL, keepAudio: Bool) -> URL? {
        guard !keepAudio else { return nil }
        // The two APIs disagree in this SDK: one wants an array, the other a set.
        let listed: [URLResourceKey] = [.contentModificationDateKey]
        let read: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: listed)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "wav" }
            .max { left, right in
                let l = (try? left.resourceValues(forKeys: read).contentModificationDate) ?? .distantPast
                let r = (try? right.resourceValues(forKeys: read).contentModificationDate) ?? .distantPast
                return l < r
            }
    }

    /// A take's length. Used when a take is re-run outside the session that recorded it, so the note still
    /// records how long the audio was.
    static func seconds(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// How to name a take in a log line, without printing a home directory.
    static func describe(_ url: URL) -> String { url.lastPathComponent }
}
