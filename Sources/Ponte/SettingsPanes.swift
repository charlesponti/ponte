import AppKit
import SwiftUI

// MARK: - Dictations

struct DictationsPane: View {
    @ObservedObject var model: PonteWindowModel
    @ObservedObject var history: HistoryModel

    init(model: PonteWindowModel) {
        self.model = model
        self.history = model.history
    }

    private var stampFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }

    private var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }

    private func stamp(_ note: History.Note) -> String {
        guard let date = note.date else { return "—" }
        return Calendar.current.isDateInToday(date) ? stampFormatter.string(from: date)
                                                    : dayFormatter.string(from: date)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UI.ink3)
                TextField("Search the dictations", text: $history.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(UI.ink)
                Text("\(history.filtered.count) of \(history.notes.count)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UI.ink3)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            Rectangle().fill(UI.line).frame(height: 1)

            ScrollView { list }

            Rectangle().fill(UI.line).frame(height: 1)
            HStack(spacing: 8) {
                BoardButton(title: "Copy") { if let n = history.selected { history.copy(n) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                BoardButton(title: "Transcribe again") {
                    if let n = history.selected { history.retranscribe(n) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                BoardButton(title: "Show note") { if let n = history.selected { history.reveal(n) } }
                Spacer(minLength: 10)
                Text(history.message ?? defaultHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(UI.ink3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
        }
    }

    private var defaultHint: String {
        history.notes.isEmpty ? "Nothing dictated yet" : "Double-click a dictation to copy it"
    }

    @ViewBuilder private var list: some View {
        if UI.variant.groupsByDay {
            // Pinned day headers, so the date stops being a column repeated on every row.
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(DaySection.group(history.filtered)) { section in
                    Section {
                        ForEach(section.notes) { note in row(note) }
                    } header: {
                        dayHeader(section)
                    }
                }
            }
        } else {
            VStack(spacing: 0) {
                ForEach(history.filtered) { note in row(note) }
            }
        }
    }

    private func dayHeader(_ section: DaySection) -> some View {
        HStack(spacing: 8) {
            Text(section.title.uppercased())
                .font(.system(size: 10)).tracking(1.1)
                .foregroundStyle(UI.ink3)
            Text(section.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(UI.ink3.opacity(0.75))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 7)
        .background(UI.window)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UI.brass.opacity(0.22)).frame(height: 1)
        }
    }

    private func time(_ note: History.Note) -> String {
        guard let date = note.date else { return "—" }
        return stampFormatter.string(from: date)
    }

    @ViewBuilder private func row(_ note: History.Note) -> some View {
        if UI.variant.groupsByDay { stackedRow(note) } else { inlineRow(note) }
    }

    /// Time above the sentence; the duration is the length of a tick in the margin. Only real data — a longer take
    /// draws a longer tick, and nothing is invented.
    private func stackedRow(_ note: History.Note) -> some View {
        let selected = history.selection == note.id
        // Once a row is open, the prose *is* the row: repeating the sentence at 13 pt above it and the duration in
        // both the meta line and the footer says everything twice.
        let reading = selected && UI.variant.reads
        let seconds = CGFloat(DaySection.seconds(of: note))
        return HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(selected ? UI.accent : UI.brass.opacity(0.55))
                .frame(width: 2, height: 9 + min(17, seconds * 1.15))
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(time(note))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(UI.ink3)
                    if !reading, !note.duration.isEmpty {
                        Text(note.duration).font(.system(size: 11)).foregroundStyle(UI.ink3)
                    }
                }

                if reading {
                    self.reading(note)
                } else {
                    Text(note.title)
                        .font(.system(size: 13))
                        .foregroundStyle(UI.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(selected ? UI.selection.opacity(0.7) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { history.selection = note.id }
    }

    /// The dictation read as prose: serif at reading size, the facts underneath, the actions where they belong.
    private func reading(_ note: History.Note) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(note.text)
                .font(.system(size: 19, design: .serif))
                .lineSpacing(5)
                .foregroundStyle(UI.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let fresh = history.retranscribed, fresh.noteID == note.id {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TRANSCRIBED AGAIN")
                        .font(.system(size: 10)).tracking(1.1)
                        .foregroundStyle(UI.ink3)
                    Text(fresh.text)
                        .font(.system(size: 17, design: .serif))
                        .lineSpacing(4)
                        .foregroundStyle(UI.ink2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Text([note.duration, note.engine].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(UI.ink3)
                Spacer(minLength: 8)
                BoardButton(title: "Copy") { history.copy(note) }
                BoardButton(title: "Transcribe again") { history.retranscribe(note) }
                BoardButton(title: "Show note") { history.reveal(note) }
            }
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
    }

    /// The shipped layout, for `plain`.
    private func inlineRow(_ note: History.Note) -> some View {
        let selected = history.selection == note.id
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(stamp(note))
                .font(.system(size: 12))
                .foregroundStyle(UI.ink3)
                .frame(width: 74, alignment: .leading)
            Text(note.duration.isEmpty ? "—" : note.duration)
                .font(.system(size: 11.5))
                .foregroundStyle(UI.ink3)
                .frame(width: 40, alignment: .trailing)
            Text(note.title)
                .font(.system(size: 13))
                .foregroundStyle(selected ? UI.accent : UI.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(selected ? UI.selection : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(UI.hairline).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            history.selection = note.id
            history.copy(note)
        }
        .onTapGesture {
            history.selection = note.id
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var model: PonteWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "General", sub: "What Ponte does when you press the key, and what it starts up with.")

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    Text("Hotkey").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    if model.recording {
                        Text("Press the new keys — Esc cancels")
                            .font(.system(size: 13))
                            .foregroundStyle(UI.accent)
                    } else {
                        KeyCaps(chord: model.hotKey)
                    }
                    Spacer(minLength: 8)
                    if !model.recording {
                        BoardButton(title: "Record…") { model.startRecording() }
                    }
                }
                .frame(minHeight: 34)
                .padding(.vertical, 7)

                if let note = model.recorderMessage {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(UI.amber)
                        .padding(.leading, 146)
                        .padding(.bottom, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .center, spacing: 14) {
                    Text("Dictation key")
                        .font(.system(size: 13)).foregroundStyle(UI.ink)
                        .frame(width: 132, alignment: .leading)
                    Picker("", selection: Binding(get: { model.hotKeyMode },
                                                  set: { model.setHotKeyMode($0) })) {
                        ForEach(HotKeyMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 34)
                .padding(.vertical, 7)

                HStack(alignment: .center, spacing: 14) {
                    Text("Microphone")
                        .font(.system(size: 13)).foregroundStyle(UI.ink)
                        .frame(width: 132, alignment: .leading)
                    Picker("", selection: Binding(get: { model.inputUID ?? "" },
                                                  set: { model.setInput($0) })) {
                        Text("System default — \(model.systemDefaultName)").tag("")
                        Divider()
                        ForEach(model.inputs) { input in
                            Text(input.name).tag(input.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 34)
                .padding(.vertical, 7)

                if model.micFellBack {
                    Text("\(model.pinnedName ?? "The chosen microphone") isn't connected — this take uses \(model.deviceName).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(UI.amber)
                        .padding(.leading, 146)
                        .padding(.bottom, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Split()

                ToggleLine(label: "Paste after", on: "On — at the cursor, in whatever you're writing",
                           off: "Off — the text is only copied", value: model.autoPaste, set: model.setAutoPaste)
                ToggleLine(label: "Keep audio", on: "On — takes are kept next to their notes",
                           off: "Off — takes are deleted once transcribed", value: model.keepAudio, set: model.setKeepAudio)
                ToggleLine(label: "At login", on: "On — Ponte starts with your Mac",
                           off: "Off — start it yourself", value: model.atLogin, set: model.setAtLogin)

                Split()

                HStack(alignment: .center, spacing: 14) {
                    Text("Vocabulary").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text(model.vocabularyLine).font(.system(size: 13)).foregroundStyle(UI.ink2)
                    Spacer(minLength: 8)
                    BoardButton(title: "Edit rules…", mint: true) { model.actions.editVocabulary() }
                }
                .frame(minHeight: 34)
                .padding(.vertical, 7)

                Text("Plain JSON you own, applied to every transcription. Whole words only, longest phrase first.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UI.ink3)
                    .padding(.leading, 146)
            }
            .frame(maxWidth: UI.contentMax, alignment: .leading)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.version) · \(model.model.label) on the Neural Engine · \(languageName)")
                Text("Your audio and text never leave the Mac. The only request Ponte makes is checking for its own updates.")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(UI.ink3)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var languageName: String {
        model.languages.first { $0.code == model.language }?.label ?? model.language
    }
}

// MARK: - Speech

struct SpeechPane: View {
    @ObservedObject var model: PonteWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Speech", sub: "One engine, on the Neural Engine. Parakeet Ultra is the model that ships.")

            Text("MODEL").font(.system(size: 10)).tracking(1.1).foregroundStyle(UI.ink3).padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ParakeetModel.allCases), id: \.self) { m in
                    let installed = ParakeetEngine.shared.isInstalled(m)
                    Button { model.setModel(m) } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .strokeBorder(model.model == m ? UI.accent : UI.ink3, lineWidth: 1.4)
                                .background(Circle().fill(model.model == m ? UI.accent : .clear).padding(3))
                                .frame(width: 14, height: 14)
                            Text(m.label).font(.system(size: 13)).foregroundStyle(UI.ink)
                            Text(installed ? "· downloaded" : "· not downloaded")
                                .font(.system(size: 11.5)).foregroundStyle(UI.ink3)
                            Spacer(minLength: 8)
                            if !installed {
                                BoardButton(title: "Download") { model.actions.downloadModel(m) }
                            }
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: UI.contentMax, alignment: .leading)

            Split()

            Text("LANGUAGE").font(.system(size: 10)).tracking(1.1).foregroundStyle(UI.ink3).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.languages, id: \.code) { lang in
                    Button { model.setLanguage(lang.code) } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .strokeBorder(model.language == lang.code ? UI.accent : UI.ink3, lineWidth: 1.4)
                                .background(Circle().fill(model.language == lang.code ? UI.accent : .clear).padding(3))
                                .frame(width: 14, height: 14)
                            Text(lang.label).font(.system(size: 13)).foregroundStyle(UI.ink)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: UI.contentMax, alignment: .leading)

            Spacer(minLength: 12)
            Text("The model runs in this process on the Neural Engine. Nothing is uploaded, and the audio never leaves the Mac.")
                .font(.system(size: 11.5)).foregroundStyle(UI.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }
}

// MARK: - Updates

struct UpdatesPane: View {
    @ObservedObject var model: PonteWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Updates", sub: "Ponte checks for its own updates. That request carries nothing about you.")

            VStack(alignment: .leading, spacing: 0) {
                ToggleLine(label: "Check for updates", on: "On — once a day, in the background",
                           off: "Off — check by hand", value: model.autoChecks, set: model.setAutoChecks)

                HStack(alignment: .center, spacing: 14) {
                    Text("Last check").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text(model.lastCheckLine).font(.system(size: 13)).foregroundStyle(UI.ink2)
                    Spacer(minLength: 8)
                    BoardButton(title: "Check now") { model.actions.checkForUpdates() }
                }
                .frame(minHeight: 34)
                .padding(.vertical, 7)

                if let update = model.updateAvailable {
                    Text("\(update) is available — the menu can install it.")
                        .font(.system(size: 12))
                        .foregroundStyle(UI.accent)
                        .padding(.leading, 146)
                        .padding(.top, 2)
                }

                Split()

                Line(label: "Version") { Text(model.version) }
                Text("The feed sends back an appcast and nothing else: no account, no identifier, and system profiling is off. A failed check says nothing at all.")
                    .font(.system(size: 11.5)).foregroundStyle(UI.ink3)
                    .padding(.leading, 146)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: UI.contentMax, alignment: .leading)

            Spacer(minLength: 12)
            Text("Sparkle installs the new build, verifies its signature, and relaunches Ponte.")
                .font(.system(size: 11.5)).foregroundStyle(UI.ink3)
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }
}

// MARK: - About

struct AboutPane: View {
    @ObservedObject var model: PonteWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "About", sub: "Version, files, and the two permissions macOS asks for.")

            VStack(alignment: .leading, spacing: 0) {
                Line(label: "Ponte") { Text("\(model.version) · Apple Silicon") }
                Line(label: "Engine") { Text("\(model.model.label) on the Neural Engine") }

                Split()

                HStack(alignment: .center, spacing: 14) {
                    Text("Notes").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text("~/Documents/Ponte").font(.system(size: 13)).foregroundStyle(UI.ink2)
                    Spacer(minLength: 8)
                    BoardButton(title: "Open") { model.actions.openNotes() }
                }
                .frame(minHeight: 34)

                HStack(alignment: .center, spacing: 14) {
                    Text("Audio").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text(model.keepAudio ? "kept next to the notes" : "deleted after each transcription")
                        .font(.system(size: 13)).foregroundStyle(UI.ink2)
                    Spacer(minLength: 8)
                    BoardButton(title: "Open") { model.actions.openAudio() }
                }
                .frame(minHeight: 34)

                HStack(alignment: .center, spacing: 14) {
                    Text("Models").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text("in Application Support").font(.system(size: 13)).foregroundStyle(UI.ink2)
                    Spacer(minLength: 8)
                    BoardButton(title: "Reveal") { model.actions.revealModels() }
                }
                .frame(minHeight: 34)

                Split()

                HStack(alignment: .center, spacing: 14) {
                    Text("Microphone").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text(model.micGranted ? "granted" : "not granted")
                        .font(.system(size: 13))
                        .foregroundStyle(model.micGranted ? UI.ink2 : UI.amber)
                    Spacer(minLength: 8)
                    if !model.micGranted { BoardButton(title: "Grant…") { model.actions.grantMicrophone() } }
                }
                .frame(minHeight: 34)

                HStack(alignment: .center, spacing: 14) {
                    Text("Pasting").font(.system(size: 13)).foregroundStyle(UI.ink).frame(width: 132, alignment: .leading)
                    Text(model.accessibilityGranted ? "granted — text is typed at the cursor"
                                                   : "not granted — text goes to the clipboard instead")
                        .font(.system(size: 13))
                        .foregroundStyle(model.accessibilityGranted ? UI.ink2 : UI.amber)
                    Spacer(minLength: 8)
                    if model.accessibilityGranted {
                        BoardButton(title: "Repair…") { model.actions.repairPermissions() }
                    } else {
                        BoardButton(title: "Grant…") { model.actions.grantAccessibility() }
                    }
                }
                .frame(minHeight: 34)

                Text("Repair clears a grant left behind by an old build and asks again — the fix when the pane says granted and pasting still does not work.")
                    .font(.system(size: 11.5)).foregroundStyle(UI.ink3)
                    .padding(.leading, 146)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: UI.contentMax, alignment: .leading)

            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Text("charlesponti.github.io/ponte").font(.system(size: 11.5)).foregroundStyle(UI.ink3)
                BoardButton(title: "Open page") { model.actions.openSite() }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }
}

