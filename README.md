# VoiceNote

Push-to-talk dictation for macOS. Press a hotkey, talk, and the text appears at your cursor.
Everything runs on your Mac — no network calls, no account, no subscription.

```
⌥⌘Space   start recording  (press again to stop)
          → a 96 px squircle holding the orb, mint and spinning fast while it listens
          → Parakeet on the Neural Engine (default) or whisper.cpp on the CPU
          → done: the orb turns green and the box collapses to the text + 16 px padding
          → error: the orb shrinks, turns red, throbs three times, then the box follows
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
| `Sources/VoiceNote/Orb.swift` | the orb: lattice, projection, depth layers, and the whole lifecycle spec (`HudSpec`) |
| `Sources/VoiceNote/HUD.swift` | the floating squircle, its collapse animation, and the offscreen renderer |
| `Sources/VoiceNote/HotKey.swift` | Carbon global hotkey (no Accessibility permission needed to *trigger*) |
| `scripts/build-app.sh` | builds and ad-hoc signs `VoiceNote.app`, copies SPM resource bundles |
| `scripts/make-icon.sh` | regenerates the app icon with ImageMagick |

## Build & install

```bash
./scripts/build-app.sh            # → dist/VoiceNote.app
./scripts/build-app.sh --install  # → /Applications and launch
```

### Signing (don't skip this)

The script signs with your **Apple Development** identity, falling back to `Developer ID Application`,
then ad-hoc. This matters more than it looks:

- An ad-hoc signature (`codesign --sign -`) has a designated requirement of `cdhash H"…"`, which
  changes on **every rebuild**. macOS then can't match your existing TCC grants and re-prompts for the
  microphone and Accessibility after each build — the classic "why does it keep asking me?" loop.
- Signing with a certificate keys the requirement to the cert + bundle id:

  ```
  identifier "com.ponti.voicenote" and anchor apple generic
    and certificate leaf[subject.CN] = "Apple Development: …"
  ```

  Grants then survive rebuilds. Verified: two rebuilds after granting, zero
  `Failed to match existing code requirement` lines in the TCC log, recording started with no prompt.

Override the identity with `VOICENOTE_SIGN_ID="Developer ID Application: …" ./scripts/build-app.sh`.

If you ever switch identity, the old grants are dead — clear them and re-grant once:

```bash
tccutil reset Accessibility com.ponti.voicenote
tccutil reset Microphone com.ponti.voicenote
```

## Requirements

- FluidAudio 0.17.7 (Swift Package, resolved automatically) — runs Parakeet on the ANE
- `brew install whisper-cpp` (v1.9.5) — only needed for the whisper.cpp engine
- whisper models in `~/Library/Application Support/VoiceNote/models/`
  - `ggml-large-v3-turbo.bin` — default, most accurate
  - `ggml-base.en.bin` — fallback, fast but noticeably worse punctuation
- Parakeet models in `~/Library/Application Support/FluidAudio/Models/`. They download on first use,
  or up front with `VoiceNote --download ultra`. Ultra's encoder is 595 MB (int8, ANE).

## The HUD

The HUD is a **96 px squircle holding an orb of 1,100 dots**, borrowed from
[Waveform](~/Developer/Waveform) and reproduced from its maths — Fibonacci lattice, four depth layers at
opacity `[0.18, 0.4, 0.7, 1.0]`, perspective `0.75 + 0.25·depth`, spin 0.35 rad/s, tip 0.35.

| State | Orb | Box |
|---|---|---|
| Recording | mint, **4× spin**, label is a live `m:ss` clock, **dots answer your voice** | 96 × 96 |
| Working / downloading | mint, calm spin, label `…` or `43%` | 96 × 96 |
| Done | mint → green, shrinks to nothing, label `Pasted ✓` | 96 × 96 → **text + 16 px all round** |
| Error | mint → red, shrinks to 82%, **three throbs**, then exits | 96 × 96 through the throbs, then collapses |

### The voice

The orb is Waveform's model, ported whole (`OrbModel.sample`, `ColumnWindow`, `ColumnBuilder`):

- **One entry per meter tick**, level and peak, from the recorder's `averagePower` and `peakPower`,
  both mapped from dBFS the way Waveform's `Scale.decibels` maps a sample onto its display range.
- **Meter ballistics**: the level rises at once and falls away over 0.15 s, so a word is a swell that
  decays rather than a flicker.
- **Read back with a Catmull-Rom curve** through four neighbours, and the newest column advances
  smoothly *between* ticks, so a 30 Hz meter still ripples instead of stepping.
- **`out = 1 + gain · level`** pushes dots outward and **`1.1 + 2.4 · peak + (out − 1)`** (over 1.1)
  makes a peak's dots bigger. Measured: 49 pt across at silence, 64 pt at full voice.
- **Gain is 0.25, not Waveform's 0.45.** Waveform's orb has a canvas of its own; this one shares a fixed
  96 px box with a label, and 0.45 would push the dots into it. At 0.25 the loudest voice lands on exactly
  the 60 px orb the board draws.

The box is **black** (94 %, hairline border), not the usual translucent `.hudWindow` material: the outer
dots are drawn at 18 % opacity and were lost against grey. Black raised measured dot contrast 1.14–1.20×.

Design decisions worth knowing before changing it:

- **The box only collapses on done and error**, and on error only *after* the third throb — the throbs are
  the orb talking, so the container holds still while they happen.
- **The throb scales the object, not the dots.** Pushing dots outward is how this model expresses loudness;
  throbbing that way would be lying about the audio.
- **The pill is measured from the rendered string**, so whatever it ends up saying sizes correctly:
  `Pasted ✓` collapses to 89 × 47, the same shape with times in it collapsed to 119 × 47.
- **A glanceable pill carries one fact.** `Pasted ✓` says what happened; the recorded length and the transcribe
  time go to the log and the note's frontmatter, where they can be read properly. An earlier version showed
  `8.1s → 0.2s` in the pill, which needed a legend to mean anything.
- **The recording clock is live** (`HudLifecycle.clock`, m:ss), driven by the same display-link tick that turns
  the orb — a timer, not a caption.

> Note: the board `design/hud-b-lifecycle-v2.html` was drawn with `Pasted ✓ 0.2s` in the pill, which is why it
> measures 118 × 47. The mechanism is the same; only the string changed.
- **The box sinks**: its bottom edge stays 96 px above the visible frame while the height shrinks.
- Dot count stays at 1,100 as the orb shrinks — the whole object scales, so the dots scale with it.

### Seeing it without a screen grab

```bash
VoiceNote --hud-strip /tmp/hud.png          # the lifecycle as a contact sheet, drawn by the app
VoiceNote --hud-render /tmp/one.png done 0.45   # one frame: <out.png> <state> [t] [text]
VoiceNote --hud-voice /tmp/voice.png            # the orb answering a voice: levels + a spoken word
VoiceNote --orb-level /tmp/l.png 0.75           # one recording frame at a voice level
```

`--hud-strip` is the honest way to review the HUD: it is the app's own renderer, not a mockup. The blur
material is approximated with a solid fill offscreen; everything else is the real drawing path.

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

- **Microphone** — required. Prompted on first recording; also under **Permissions ▸ Microphone**.
- **Accessibility** — only needed for auto-paste (sending ⌘V). Without it the transcript still lands
  on the clipboard and the HUD says "Copied to clipboard"; the app logs one quiet notice per launch
  rather than raising the system dialog at the end of every dictation. Grant it in
  **Permissions ▸ Accessibility**, restart, done.
- **Documents folder** — macOS asks the first time a note is written to `~/Documents/VoiceNotes`.
  One grant, then it sticks (as long as the signature is stable). Move `AppPaths.transcripts` into
  `~/Library/Application Support/VoiceNote/` to avoid this prompt entirely.

After granting Accessibility, the running process usually needs a restart before it takes effect —
`AXIsProcessTrusted()` is cached per launch.

## Menu

- Start / Stop recording (shows the current hotkey)
- Copy last transcript · Open notes folder · Open audio folder
- **Model** — whisper.cpp models, plus downloads for ones that aren't
- **Language** — 15 languages incl. auto-detect (mapped onto Parakeet's language hint)
- **Engine** — whisper.cpp vs Parakeet; Parakeet Ultra / v3 / v2 / Redux; download or unload
- Auto-paste into frontmost app · Keep audio files · Launch at Login
- **Permissions** — mic + accessibility status and shortcuts to Settings

## Setting the hotkey

Two defaults, then restart the app (the hotkey is registered at launch):

```bash
# ⌃⌥D = kVK_ANSI_D (2) with controlKey (4096) + optionKey (2048)
defaults write com.ponti.voicenote hotKeyCode -int 2
defaults write com.ponti.voicenote hotKeyMods -int 6144
```

Hex works too, if you'd rather read straight from a header: `-string 0x02` and `-string 0x1800`.

Back to the default ⌥⌘Space:

```bash
defaults delete com.ponti.voicenote hotKeyCode
defaults delete com.ponti.voicenote hotKeyMods
```

If another app already owns the chord, VoiceNote logs `hotkey registration failed`, posts a
notification, and the menu item still works — pick a different chord.

### Modifier masks

Add them together: ⌃⌥ = 6144, ⌥⌘ = 2304, ⌃⇧⌘ = 4864.

| Key | Value |
|---|---|
| ⌘ cmdKey | 256 |
| ⇧ shiftKey | 512 |
| ⌥ optionKey | 2048 |
| ⌃ controlKey | 4096 |

### Key codes

Straight from Carbon's `Events.h`, so these are authoritative for macOS 27:

| | |
|---|---|
| Letters | A 0 · S 1 · D 2 · F 3 · H 4 · G 5 · Z 6 · X 7 · C 8 · V 9 · B 11 · Q 12 · W 13 · E 14 · R 15 · Y 16 · T 17 |
| Digits | 1 18 · 2 19 · 3 20 · 4 21 · 6 22 · 5 23 · 9 25 · 7 26 · 8 28 · 0 29 |
| Symbols | `=` 24 · `-` 27 · `]` 30 · `[` 33 · `'` 39 · `;` 41 · `\` 42 · `,` 43 · `/` 44 · `.` 47 · `` ` `` 50 |
| Editing | Return 36 · Tab 48 · Space 49 · Delete 51 · ForwardDelete 117 · Escape 53 |
| Arrows | ← 123 · → 124 · ↓ 125 · ↑ 126 |
| Navigation | Help 114 · Home 115 · PageUp 116 · End 119 · PageDown 121 |
| Function | F1 122 · F2 120 · F3 99 · F4 118 · F5 96 · F6 97 · F7 98 · F8 100 · F9 101 · F10 109 · F11 103 · F12 111 · F13 105 · F14 107 · F15 113 |

Key code `0` is the **A** key — a real value, not "unset" (the app reads the defaults with
`object(forKey:)` so it can tell the difference).

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
VoiceNote --hud-strip hud.png                    # the HUD lifecycle as a contact sheet
VoiceNote --hud-render hud.png error 0.64        # one HUD frame at a moment in a state
```
