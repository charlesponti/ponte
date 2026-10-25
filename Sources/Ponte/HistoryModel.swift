import AppKit
import SwiftUI

/// The state behind the Dictations pane: what is on disk, what is being searched for, and what has been re-run.
@MainActor
final class HistoryModel: ObservableObject {
    @Published var notes: [History.Note] = []
    @Published var query = ""
    @Published var selection: History.Note.ID?
    /// The last thing that happened, said plainly in the footer rather than as a dialog.
    @Published var message: String?
    /// A fresh transcription of the selected take, when one has been asked for.
    @Published var retranscribed: String?

    var filtered: [History.Note] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? notes : notes.filter { $0.matches(needle) }
    }

    var selected: History.Note? { notes.first { $0.id == selection } }

    func reload() {
        notes = History.notes()
        if selection == nil || !notes.contains(where: { $0.id == selection }) {
            selection = filtered.first?.id
        }
    }

    /// Copy a note's text. This is the thing the window is for: getting yesterday's sentence back.
    func copy(_ note: History.Note) {
        let text = note.text
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        message = "copied \(text.count) characters"
    }

    /// Run the engine again over the audio that was kept, and copy the result.
    ///
    /// The note is left alone: it is what the engine said at the time, and rewriting history to match a newer model
    /// would be a quiet lie. The fresh text is shown beside it and copied, so it can be pasted over deliberately.
    func retranscribe(_ note: History.Note) {
        guard let audio = note.audioURL, note.hasAudio else {
            message = "the audio for this take was deleted"
            return
        }
        retranscribed = nil
        message = "transcribing…"
        Task.detached(priority: .userInitiated) {
            do {
                let result = try AsrEngine.transcribe(wav: audio, parakeetModel: Settings.parakeetModel,
                                                      language: Settings.language)
                let fresh = Vocabulary.load().applied(to: result.text)
                await MainActor.run {
                    self.retranscribed = fresh
                    self.message = String(format: "transcribed again in %.2fs — copied", result.seconds)
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(fresh, forType: .string)
                }
            } catch {
                await MainActor.run { self.message = "could not transcribe it again: \(error.localizedDescription)" }
            }
        }
    }

    func reveal(_ note: History.Note) {
        NSWorkspace.shared.activateFileViewerSelecting([note.url])
    }
}
