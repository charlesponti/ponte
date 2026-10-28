import AppKit
import SwiftUI

/// The state behind the Dictations pane: what is on disk, what is being searched for, and what has been re-run.
@MainActor
final class HistoryModel: ObservableObject {
    struct Retranscription: Equatable {
        let noteID: History.Note.ID
        let text: String
    }

    @Published var notes: [History.Note] = []
    @Published var query = ""
    @Published var selection: History.Note.ID? {
        didSet {
            guard selection != oldValue else { return }
            latestRetranscriptionID = nil
            retranscribed = nil
            if message == "transcribing…" { message = nil }
        }
    }
    /// The last thing that happened, said plainly in the footer rather than as a dialog.
    @Published var message: String?
    /// A fresh transcription of the selected take, when one has been asked for.
    @Published var retranscribed: Retranscription?
    private var latestRetranscriptionID: UUID?

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
        let requestID = beginRetranscription(for: note.id)
        Task.detached(priority: .userInitiated) {
            do {
                let result = try AsrEngine.transcribe(wav: audio, parakeetModel: Settings.parakeetModel,
                                                      language: Settings.language)
                let fresh = Vocabulary.load().applied(to: result.text)
                await MainActor.run {
                    guard self.acceptRetranscription(fresh, for: note.id,
                                                     requestID: requestID, seconds: result.seconds) else { return }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(fresh, forType: .string)
                }
            } catch {
                await MainActor.run {
                    guard self.latestRetranscriptionID == requestID, self.selection == note.id else { return }
                    self.latestRetranscriptionID = nil
                    self.message = "could not transcribe it again: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Apply a completion only while it still belongs to the selected note and latest request.
    /// Kept separate from the engine call so the stale-result rule can be tested without loading a model.
    func beginRetranscription(for noteID: History.Note.ID) -> UUID {
        selection = noteID
        let requestID = UUID()
        latestRetranscriptionID = requestID
        retranscribed = nil
        message = "transcribing…"
        return requestID
    }

    @discardableResult
    func acceptRetranscription(_ text: String, for noteID: History.Note.ID,
                               requestID: UUID, seconds: Double) -> Bool {
        guard latestRetranscriptionID == requestID, selection == noteID else { return false }
        latestRetranscriptionID = nil
        retranscribed = Retranscription(noteID: noteID, text: text)
        message = String(format: "transcribed again in %.2fs — copied", seconds)
        return true
    }

    func reveal(_ note: History.Note) {
        NSWorkspace.shared.activateFileViewerSelecting([note.url])
    }
}
