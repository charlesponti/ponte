import AppKit
import SwiftUI

/// The state behind the history window: what is on disk, what is being searched for, and what has been re-run.
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

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search the dictations", text: $model.query)
                    .textFieldStyle(.plain)
                Text("\(model.filtered.count) of \(model.notes.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reload") { model.reload() }.controlSize(.small)
            }
            .padding(10)
            Divider()

            HSplitView {
                List(model.filtered, selection: $model.selection) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(note.date.map { History.Note.stamp.string(from: $0) } ?? "no date")
                            Text(note.duration)
                            if !note.engine.isEmpty { Text(note.engine) }
                            if note.hasAudio { Image(systemName: "waveform") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(note.id)
                }
                .frame(minWidth: 280)

                detail
            }

            Divider()
            HStack(spacing: 10) {
                Button("Copy") { if let note = model.selected { model.copy(note) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.selected == nil)
                Button("Transcribe Again") { if let note = model.selected { model.retranscribe(note) } }
                    .disabled(model.selected?.hasAudio != true)
                Button("Show Note") { if let note = model.selected { model.reveal(note) } }
                    .disabled(model.selected == nil)
                Spacer()
                Text(model.message ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(10)
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { model.reload() }
    }

    @ViewBuilder private var detail: some View {
        if let note = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(note.date.map { History.Note.stamp.string(from: $0) } ?? "no date")
                        .font(.headline)
                    Text(note.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let fresh = model.retranscribed {
                        Divider()
                        Text("Transcribed again just now").font(.subheadline).foregroundStyle(.secondary)
                        Text(fresh)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
        } else {
            Text("No dictations yet").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The window, made once and reused. A plain titled window, unlike the HUD: this one is meant to take focus and be
/// typed in, and it is opened deliberately rather than appearing while somebody is writing.
@MainActor
final class HistoryWindow {
    private var window: NSWindow?
    private let model = HistoryModel()

    func show() {
        if let window {
            model.reload()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Ponte — History"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: HistoryView(model: model))
        w.center()
        window = w
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
