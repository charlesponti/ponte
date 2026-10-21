# VoiceNote

Push-to-talk dictation for macOS. Press a hotkey, talk, and the text appears at your cursor.
Everything runs on your Mac — no network calls, no account, no subscription.

```
⌥⌘Space   start recording  (press again to stop)
          → HUD shows a live mic level
          → Parakeet on the Neural Engine (default) or whisper.cpp on the CPU
          → text is pasted into whatever app is focused
```

Two interchangeable engines, switchable from the menu (**Engine**):

| Engine | What runs | Where |
|---|---|---|
| **Parakeet on the ANE** (default) | FluidAudio 0.17.7 → CoreML Parakeet Ultra via `AsrManager` | Apple Neural Engine, models stay resident |
| whisper.cpp | `whisper-cli` subprocess, `large-v3-turbo` | CPU, model reloaded per recording |

Installed at `/Applications/VoiceNote.app`. Lives in the menu bar (no Dock icon).

## What's in the repo

| File | Purpose |
|---|---|
| `Sources/VoiceNote/main.swift` | entry point + CLI modes (`--record`, `--transcribe`, `--bench`, `--download`, `--selftest`, `--devices`) |
| `Sources/VoiceNote/AppDelegate.swift` | menu bar item, menu, hotkey → record → transcribe → paste flow |
| `Sources/VoiceNote/Recorder.swift` | mic capture straight to 16 kHz mono 16-bit WAV (what both engines want) |
| `Sources/VoiceNote/ParakeetEngine.swift` | FluidAudio/CoreML engine + `AsrEngine` router that picks the engine |
| `Sources/VoiceNote/Transcriber.swift` | whisper.cpp subprocess, transcript saving, model downloads |
| `Sources/VoiceNote/HUD.swift` | floating level-meter pill + status states (also shows download progress) |
| `Sources/VoiceNote/HotKey.swift` | Carbon global hotkey (no Accessibility permission needed to *trigger*) |
| `scripts/build-app.sh` | builds and ad-hoc signs `VoiceNote.app`, copies SPM resource bundles |
| `scripts/make-icon.sh` | regenerates the app icon with ImageMagick |

## Build & install

```bash
./scripts/build-app.sh            # → dist/VoiceNote.app
./scripts/build-app.sh --install  # → /Applications and launch
```

## Requirements

- FluidAudio 0.17.7 (Swift Package, resolved automatically) — runs Parakeet on the ANE
- `brew install whisper-cpp` (v1.9.5) — only needed for the whisper.cpp engine
- whisper models in `~/Library/Application Support/VoiceNote/models/`
  - `ggml-large-v3-turbo.bin` — default, most accurate
  - `ggml-base.en.bin` — fallback, fast but noticeably worse punctuation
- Parakeet models in `~/Library/Application Support/FluidAudio/Models/`. They download on first use,
  or up front with `VoiceNote --download ultra`. Ultra's encoder is 595 MB (int8, ANE).

## Measured on this Mac (M1 Max, 32 GB)

Same WAV file, same machine, three runs each, best warm run:

| Engine | First run | Warm | Throughput |
|---|---|---|---|
| whisper.cpp `large-v3-turbo` (7.98 s clip) | 2.56 s | **1.76 s** | 4.5× realtime |
| Parakeet Ultra (7.98 s clip) | 0.52 s | **0.14 s** | **56.8× realtime** |

Through the app, hotkey to clipboard:

| Engine | Audio | Transcription | Stop → note on disk |
|---|---|---|---|
| Parakeet Ultra | 8.5 s | **0.2 s** | **0.50 s** |
| whisper.cpp | 6.7 s | 2.2 s | ~2.4 s |

Both produced the same transcript on the benchmark clip. Parakeet reports a per-utterance
confidence score, which is logged.

## The two numbers that matter

- **First ANE load after install is ~23 s.** CoreML specialises the model programme for the Neural
  Engine once per machine/OS; after that it is cached and loads in ~0.2 s. The app therefore warms
  the engine at launch, in the background, so a dictation never sits through it. If you ever see a
  long pause on the very first recording after a fresh model download — that is this, and it only
  happens once per model.
- **Parakeet keeps the models resident** (encoder on the ANE, ~0.1 GiB). whisper.cpp pays a
  model-reload cost on every recording because it runs as a subprocess.

## Details worth knowing

- Text normalisation is the model's own: Parakeet wrote "move the stand up to 9.30 tomorrow" for
  "nine thirty". FluidAudio's opt-in `TextNormalizer` (ITN) is **not** wired in — what you see is
  what the decoder produced.
- `Engine ▸ Unload Parakeet from memory` frees the resident models; the next recording reloads them
  (~0.2 s warm).
- Resource bundles from SwiftPM (`FluidAudio_FluidAudio.bundle`) must be copied into the app or the
  CoreML models fail to load at runtime — `build-app.sh` handles this.

## Where things go

| | |
|---|---|
| Transcripts | `~/Documents/VoiceNotes/note-<timestamp>.md` + rolling `all-notes.md` |
| Recordings | `~/Library/Application Support/VoiceNote/audio/` (deleted after use unless "Keep audio files" is on) |
| whisper models | `~/Library/Application Support/VoiceNote/models/` |
| Parakeet models | `~/Library/Application Support/FluidAudio/Models/` |
| Log | `~/Library/Application Support/VoiceNote/voicenote.log` |

Each note records which engine produced it:

```yaml
---
date: 2026-10-21T23:50:37Z
duration: 8.5s
transcribe_time: 0.2s
engine: parakeet-ultra
---
```

## Permissions

- **Microphone** — required. Requested on first launch; also under **Permissions ▸ Microphone**.
- **Accessibility** — only needed for auto-paste (sending ⌘V). Without it the transcript still lands
  on the clipboard, and the HUD says "Copied to clipboard". Grant it via
  **Permissions ▸ Accessibility**, then re-run.

## Menu

- Start / Stop recording (shows the current hotkey)
- Copy last transcript · Open notes folder · Open audio folder
- **Model** — whisper.cpp models, plus downloads for ones that aren't
- **Language** — 15 languages incl. auto-detect (mapped onto Parakeet's language hint)
- **Engine** — whisper.cpp vs Parakeet; Parakeet Ultra / v3 / v2 / Redux; download or unload
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

## Known limits / next steps

- No push-to-hold mode yet — it's press-to-start, press-to-stop.
- Parakeet TDT uses a fixed 15 s encoder window; longer recordings are chunked with 2 s overlap by
  FluidAudio, and long-form seam quality is the thing to watch if you dictate for minutes at a time.
- v3 and Redux are selectable but not downloaded here — Ultra beats v3 on every benchmark at the
  same speed, so there is little reason to switch unless you want Redux's smaller footprint.
- A stale `parakeet-tdt-0.6b-v3-coreml` directory from an older FluidAudio naming scheme still sits
  in the models folder; the current version doesn't look for it.

## CLI

```bash
VoiceNote --devices                              # list audio inputs, whisper path, models
VoiceNote --download ultra                       # fetch + ANE-compile a Parakeet model
VoiceNote --bench take.wav                       # every installed engine, 3 runs each, same file
VoiceNote --transcribe take.wav                  # uses the default engine
VoiceNote --transcribe take.wav --engine whisper --model ggml-base.en.bin
VoiceNote --transcribe take.wav --engine parakeet --parakeet-model ultra
VoiceNote --selftest 5                           # record 5 s from the mic and transcribe it
```
