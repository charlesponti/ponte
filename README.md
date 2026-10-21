# VoiceNote

Push-to-talk dictation for macOS. Hold a hotkey, talk, and the text appears at your cursor.
Everything runs on your Mac — whisper.cpp on Metal, no network calls, no account, no subscription.

```
⌥⌘Space   start recording  (press again to stop)
          → HUD shows a live mic level
          → whisper.cpp transcribes locally
          → text is pasted into whatever app is focused
```

Installed at `/Applications/VoiceNote.app`. Lives in the menu bar (no Dock icon).

## What's in the repo

| File | Purpose |
|---|---|
| `Sources/VoiceNote/main.swift` | entry point + CLI modes (`--record`, `--transcribe`, `--selftest`, `--devices`) |
| `Sources/VoiceNote/AppDelegate.swift` | menu bar item, menu, hotkey → record → transcribe → paste flow |
| `Sources/VoiceNote/Recorder.swift` | mic capture straight to 16 kHz mono 16-bit WAV (what whisper.cpp wants) |
| `Sources/VoiceNote/Transcriber.swift` | whisper.cpp subprocess, transcript saving, model downloads |
| `Sources/VoiceNote/HUD.swift` | floating level-meter pill + status states |
| `Sources/VoiceNote/HotKey.swift` | Carbon global hotkey (no Accessibility permission needed to *trigger*) |
| `scripts/build-app.sh` | builds and ad-hoc signs `VoiceNote.app` |
| `scripts/make-icon.sh` | regenerates the app icon with ImageMagick |

## Build & install

```bash
./scripts/build-app.sh            # → dist/VoiceNote.app
./scripts/build-app.sh --install  # → /Applications and launch
```

## Requirements (already present on this Mac)

- `brew install whisper-cpp` (v1.9.5)
- models in `~/Library/Application Support/VoiceNote/models/`
  - `ggml-large-v3-turbo.bin` — default, most accurate
  - `ggml-base.en.bin` — fallback, fast but noticeably worse punctuation

More models can be downloaded from the menu: **Model ▸ Download …**

## Where things go

| | |
|---|---|
| Transcripts | `~/Documents/VoiceNotes/note-<timestamp>.md` + rolling `all-notes.md` |
| Recordings | `~/Library/Application Support/VoiceNote/audio/` (deleted after use unless "Keep audio files" is on) |
| Models | `~/Library/Application Support/VoiceNote/models/` |
| Log | `~/Library/Application Support/VoiceNote/voicenote.log` |

## Permissions

- **Microphone** — required. Requested on first launch; also under **Permissions ▸ Microphone**.
- **Accessibility** — only needed for auto-paste (sending ⌘V). Without it the transcript still lands
  on the clipboard, and the HUD says "Copied to clipboard". Grant it via
  **Permissions ▸ Accessibility**, then re-run.

## Menu

- Start / Stop recording (shows the current hotkey)
- Copy last transcript · Open notes folder · Open audio folder
- **Model** — installed models, plus downloads for ones that aren't
- **Language** — 15 languages incl. auto-detect
- Auto-paste into frontmost app · Keep audio files · Launch at Login
- **Permissions** — mic + accessibility status and shortcuts to Settings

## Changing the hotkey

Defaults are stored in `com.ponti.voicenote`:

```bash
# key codes are Carbon virtual key codes; modifiers are Carbon modifier masks
defaults write com.ponti.voicenote hotKeyCode  -int 9      # kVK_ANSI_V
defaults write com.ponti.voicenote hotKeyMods  -int 2304   # ⌥⌘
```

Modifier masks: `cmdKey = 256`, `shiftKey = 512`, `optionKey = 2048`, `controlKey = 4096`.
Defaults: `keyCode 49` (Space) + `2304` (⌥⌘). Restart the app afterwards.

## Measured behaviour

- 7.6 s clip, `large-v3-turbo`: **1.6 s** wall clock including loading the 1.6 GB model.
  Warm disk cache is the difference — the first ever run was 12.8 s reading the model cold.
- Transcription is a subprocess per recording, so nothing sits resident between uses.

## Known limits / next steps

- Each recording reloads the model (~1 s). Running `whisper-server` and POSTing audio would cut
  latency to a few hundred ms, at the cost of a resident background process.
- No push-to-hold mode yet — it's click-to-start, click-to-stop.
- The brew whisper.cpp build is CPU-only (`WHISPER_METAL` is not linked in this formula).
  Building whisper.cpp from source with Metal/Core ML would speed things up further.

## CLI

```bash
VoiceNote --devices                    # list audio inputs, whisper path, models
VoiceNote --record 5 --out take.wav    # record 5 s
VoiceNote --transcribe take.wav        # transcribe a file
VoiceNote --selftest 5                 # record 5 s from the mic and transcribe it
```
