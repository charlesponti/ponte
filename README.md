# Ponte

Push-to-talk dictation for macOS. Press a hotkey, talk, and the text appears at your cursor.
Everything runs on your Mac — no network calls, no account, no subscription.

**Site** <https://charlesponti.github.io/ponte/> · **Releases** [../../releases](../../releases) · **Issues** [../../issues](../../issues)

The site is the `index.html` at the root of this repository and is published from `main` by GitHub Pages, so the
product page, the source and the download live in one place. Keeping them together is deliberate: the page
described an app that no longer existed — an engine that had been removed, a macOS version two releases back, a
feature that was never built — and nothing in the structure made that drift visible.

The engineering notes are in [`docs/`](docs/README.md): architecture, the engine and its measurements, the HUD's
lifecycle and geometry, permissions and signing, the test and measurement workflow, the pitfalls, and the open
work.

```
⌥⌘Space   start recording  (press again to stop)
          → a 96 px squircle holding the orb, mint and spinning fast while it listens
          → Parakeet on the Neural Engine, in-process, no model reload
          → done: the orb turns green and the box collapses to the text + 16 px padding
          → error: the orb shrinks, turns red, throbs three times, then the box follows
          → text is pasted into whatever app is focused
```

One engine, on the Neural Engine: FluidAudio 0.17.7 → CoreML Parakeet Ultra via `AsrManager`, models held
resident in-process. The **Speech model** submenu picks between Ultra (default), v3, v2 and Redux.

whisper.cpp was the original engine and was removed in 0.1.0: it needed a separate `brew install whisper-cpp`, so
the menu item was broken on any machine without one, and it cost 1.9 GB resident and a 1.5 GB model download to
be slower than Parakeet by an order of magnitude. The measurements that made it the incumbent, and then lost it
the job, are in [`docs/measurements.md`](docs/measurements.md).

Installed at `/Applications/Ponte.app`. Lives in the menu bar (no Dock icon).

## What's in the repo

| File | Purpose |
|---|---|
| `Sources/Ponte/main.swift` | entry point + CLI modes (`--record`, `--transcribe`, `--bench`, `--download`, `--selftest`, `--devices`) |
| `Sources/Ponte/AppDelegate.swift` | menu bar item, menu, hotkey → record → transcribe → paste flow |
| `Sources/Ponte/Recorder.swift` | mic capture straight to 16 kHz mono 16-bit WAV (what the engine wants) |
| `Sources/Ponte/ParakeetEngine.swift` | the FluidAudio/CoreML engine, plus `AsrEngine`, the single entry point |
| `Sources/Ponte/Transcriber.swift` | `Result`, and the note format — markdown whose frontmatter carries engine, timings and confidence |
| `Sources/Ponte/Orb.swift` | the orb: lattice, projection, depth layers, and the whole lifecycle spec (`HudSpec`) |
| `Sources/Ponte/HUD.swift` | the floating squircle, its collapse animation, and the offscreen renderer |
| `Sources/Ponte/HotKey.swift` | Carbon global hotkey (no Accessibility permission needed to *trigger*) |
| `scripts/build-app.sh` | builds and ad-hoc signs `Ponte.app`, copies SPM resource bundles |
| `scripts/make-icon.sh` | regenerates the app icon with ImageMagick |

## Build & install

```bash
./scripts/build-app.sh            # → dist/Ponte.app
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
  identifier "com.ponti.ponte" and anchor apple generic
    and certificate leaf[subject.CN] = "Apple Development: …"
  ```

  Grants then survive rebuilds. Verified: two rebuilds after granting, zero
  `Failed to match existing code requirement` lines in the TCC log, recording started with no prompt.

Override the identity with `PONTE_SIGN_ID="Developer ID Application: …" ./scripts/build-app.sh`.

If you ever switch identity, the old grants are dead — clear them and re-grant once:

```bash
tccutil reset Accessibility com.ponti.ponte
tccutil reset Microphone com.ponti.ponte
```

## Requirements

- FluidAudio 0.17.7 (Swift Package, resolved automatically) — runs Parakeet on the ANE
- Parakeet models, fetched on first run into `~/Library/Application Support/FluidAudio/Models/`
  - `parakeet-ultra` — default, 603 MB, most accurate
  - `parakeet-tdt-0.6b-v3` — 461 MB; `redux` 210 MB and `v2` are also selectable
- Parakeet models in `~/Library/Application Support/FluidAudio/Models/`. They download on first use,
  or up front with `Ponte --download ultra`. Ultra's encoder is 595 MB (int8, ANE).

## One package, both apps

Ponte and Thames share three products from the same package
(`github.com/charlesponti/waveform`, `from: "0.2.0"`):

| product | what it brings |
|---|---|
| `WaveformCore` | the orb's maths: the lattice, the projection, `ColumnRing`/`ColumnWindow`, `Scale`, the ballistics |
| `WaveformUI` | the SwiftUI views: `OrbView` (loudness) and `SpectrumOrbView` (pitch) |
| `WaveformCapture` | the recording engine: `EngineRecorder` + `CaptureSettings` (`.localTranscription` here, `.streamingSpeech` in Thames) |

So Ponte has no recording engine, no orb maths and no dot-drawing of its own. What is left in this
repo is what is Ponte's own: the HUD's lifecycle, the menu bar app, the hotkey, the pill, the notes,
the icon's *use* of the orb, and the engine (`FluidAudio`).

## Documentation

The engineering notes live in [`docs/`](docs/README.md) — architecture, the engines and their measurements,
the HUD's lifecycle and geometry, the menu bar and icon rules, permissions and signing, the test and
measurement workflow, the pitfalls, and the open work. Start with [docs/README.md](docs/README.md).

## Releasing it

```bash
./scripts/make-dmg.sh              # dist/Ponte-0.1.0.dmg, signed with the Developer ID certificate
./scripts/make-dmg.sh --notarize   # also submit to Apple, wait, and staple the ticket
./scripts/make-dmg.sh --install    # replace /Applications/Ponte.app with this build
```

The image holds the app, an Applications symlink, the volume icon and a short read-me. The app inside is signed
with **Developer ID Application: Charles Joseph Ponti (3QHJ2KN8AL)** — team `3QHJ2KN8AL`, which is
**Ponti & Co, LLC** — and the **hardened runtime** notarization requires, with
`com.apple.security.device.audio-input` declared.

**Notarized, and stapled, as of 0.1.0.** `--notarize` submits twice: the app first, then the disk image, stapling
each as it is accepted. Both matter, and only one of them was obvious:

- The **app's** staple is what lets it launch without reaching Apple.
- The **image's own signature and staple** are what Gatekeeper assesses when a buyer double-clicks the
  download. An unsigned image is rejected outright — `rejected, source=no usable signature` — however well
  signed the app inside it is.

The build prints Gatekeeper's verdict for both, and each should read:

```
accepted
source=Notarized Developer ID
origin=Developer ID Application: Charles Joseph Ponti (3QHJ2KN8AL)
```

It needs a credential profile, created once and stored in your keychain. Either an App Store Connect team key —
which belongs to the team, involves no password anywhere, and is what Apple recommends for automation:

```bash
xcrun notarytool store-credentials ponte-notary \
  --key AuthKey_XXXX.p8 --key-id XXXX --issuer <the issuer ID on that page>
```

or an Apple ID with an app-specific password, entered by you and never passed through a script:

```bash
xcrun notarytool store-credentials ponte-notary \
  --apple-id "<your Apple ID>" --team-id 3QHJ2KN8AL
```

Then `./scripts/make-dmg.sh --notarize` submits, waits, staples and prints the verdicts.

Checked on a hardened, Developer ID build: the app launches, registers the hotkey, and loads the
Parakeet model **on the Neural Engine in 0.2 s** — the hardened runtime does not disturb CoreML — and
a real 8.7 s dictation transcribed at confidence 1.00. Three things belong on the product page: it
needs **macOS 15**, the first launch **downloads the speech model (about 600 MB)** so everything
after runs on the buyer's Mac, and the first recording asks for the **microphone**.

There is no licence check in the app. Selling with a key means adding one — Paddle, Lemon Squeezy and
Gumroad all issue keys and handle VAT — or selling it unpoliced.

## Tests

```bash
swift test        # 56 tests, five suites, no network and no microphone
```

The suite exists because this app has one bad habit: **its bugs look fine in a still.** An orb that
collapsed as the voice got louder, an icon that smeared into a grey disc at 32 px, a menu bar glyph
drawn in the bottom-left quadrant — all of them rendered something plausible. So the tests measure
pixels the way the eye cannot:

| Suite | What it pins down |
|---|---|
| `HudLifecycleTests` | The box is the box: the clock counts up. The box holds 96 × 96 while the colour changes. Three throbs, and their peaks are at `throbStart + (n + 0.5) × period` — a strip in the app once labelled the *troughs* as peaks. The pill is the measured text plus 16 px on every side. |
| `LevelRingTests` | Catmull-Rom runs through its points, has no corners, stays in range, and reads the silence before a recording as silence. |
| `IconTests` | Every size is exactly that many pixels, every mark is centred, the 16 px tile stays bright, and the depth shading is still there at 512 px. |
| `SupportTests` | The paths carry the app's name (the rename left notes and models behind once). Notes get their frontmatter and an empty transcript writes nothing. The hotkey reads as ⌥⌘Space. |

`Probe` renders into an explicit bitmap rep rather than `lockFocus`, because a measurement that
depends on the machine's display scale is not a measurement.

## The mark

The app icon is **the orb itself**, drawn by the app's own renderer — `scripts/make-icon.sh` calls
`Ponte --icon` for every size Apple's icon grid wants. It cannot drift from the thing it depicts.

- **Each size is rendered at that size**, and the renderer grows the dots relative to the sphere as the
  tile shrinks (`IconRenderer.dotScale`). Without that hint a 240-dot sphere averages into a grey smudge
  at 64 px and is gone by 16 px; with it the same drawing is a dotted sphere at 512 and a solid dot at 16.
- Four marks are available — `orb`, `halftone`, `ripple`, `core` — and all four survive to 16 px.
- **The menu bar wears a silhouette, not the dots.** At 18 pt the dots merge into a fuzzy disc, so the
  menu bar gets the sphere's outline: a core and a ring, as a template image the system tints for light
  and dark bars. At rest only; the momentary states keep their own glyphs, because "recording" is worth
  more than branding while it is happening (the orb is on screen in the HUD by then anyway).

```bash
./scripts/make-icon.sh orb        # writes Resources/AppIcon.icns, 16–1024 px
Ponte --icon-sheet /tmp/marks.png # every mark at every size, for choosing
Ponte --status-icon /tmp/bar.png  # the menu bar mark on its own
```

## The HUD

The HUD is a **squircle holding an orb of 1,100 dots**, borrowed from
the shared `Waveform` package and reproduced from its maths — Fibonacci lattice, four depth layers at
opacity `[0.18, 0.4, 0.7, 1.0]`, perspective `0.75 + 0.25·depth`, spin 0.35 rad/s, tip 0.35.

| State | Orb | Box |
|---|---|---|
| Recording | mint, **4× spin**, **dots answer your voice**; clock and live transcript beneath it | **330 × 156** |
| Working / downloading | mint, calm spin; clock holds the take's length | 330 × 156, or 104 × 104 for a download |
| Done | mint → green, shrinks to nothing, label `Pasted ✓` | full box → **text + 16 px all round** |
| Error | mint → red, shrinks to 82%, **three throbs**, then exits | the full box through the throbs, then collapses |

The wide box is for the live transcript: one line of speech at 12.5 pt needs about 260 pt, and a 104 pt square
holds an orb and a clock and nothing else. Recording and working share it, so the box does not jump when the
engine starts thinking. Words arrive at the rate they were *spoken* — measured from the take, not assumed — and
each resolves out of a blur in `0.72 / rate` seconds. [docs/hud.md](docs/hud.md) derives it.

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
Ponte --hud-strip /tmp/hud.png          # the lifecycle as a contact sheet, drawn by the app
Ponte --hud-render /tmp/one.png done 0.45   # one frame: <out.png> <state> [t] [text]
Ponte --hud-voice /tmp/voice.png                # the orb answering a voice: levels + a spoken word
```

`--hud-strip` is the honest way to review the HUD: it is the app's own renderer, not a mockup. The blur
material is approximated with a solid fill offscreen; everything else is the real drawing path.

## Measured on this Mac (M1 Max, 32 GB)

Same WAV file, same machine, three runs each, best warm run:

| Engine | First run | Warm | Throughput |
|---|---|---|---|
| whisper.cpp `large-v3-turbo` (7.98 s clip) | 2.56 s | **1.76 s** | 4.5× realtime |
| Parakeet Ultra (7.98 s clip) | 0.52 s | **0.14 s** | **56.8× realtime** |

whisper.cpp was removed in 0.1.0. It stays in this table because it is what "Parakeet is fast" is fast *compared
to* — without a second number, the first one means nothing.

Through the app, hotkey to clipboard:

| Engine | Audio | Transcription | Stop → note on disk |
|---|---|---|---|
| Parakeet Ultra | 8.5 s | **0.2 s** | **0.50 s** |
| whisper.cpp | 6.7 s | 2.2 s | ~2.4 s |

Both produced the same transcript on the benchmark clip. Parakeet reports a per-utterance
confidence score, which is logged.

### Idle cost, and the way to measure it

Ponte sits at **0.0 % CPU, 22 MB and 4 threads** with nothing happening, over three consecutive
three-second intervals, and macOS shows **no microphone-in-use pill** — the audio engine is stopped and
released when a recording ends. The opening word is not clipped either: a hotkey press with speech
starting immediately recorded 6.89 s and transcribed all 52 characters of the sentence, first word included.

Measure this with **interval samples**, never with `ps %CPU` or the first line of `top -l`: both report an
average *since the process started*, so a session that has been transcribing reads as several percent and
looks like an idle cost. The "2.7 % at idle" that started issue #9 was exactly that — a lifetime mean on a
process that had just done dictations. Three idle threads are Core Animation and friends; four is a quiet
Cocoa app.

```
PID=$(pgrep -f MacOS/Ponte | head -1)
top -l 5 -s 3 -pid "$PID" -stats pid,cpu,mem,threads,time    # read the samples after the first
```

### Long dictations

Synthetic speech carrying a countable pattern — 120 repetitions of one sentence plus a closing marker —
through the CLI, so the engine is the only variable:

Measured to six minutes, and reproduced by `./scripts/long-dictation-check.sh`:

| audio | model | time | repetitions kept | peak RSS |
|---|---|---|---|---|
| 20 s | ultra | 0.7-1.2 s | 6 of 6 | ~100 MB |
| 76 s | ultra | 0.7-1.7 s | 24 of 24 | ~120 MB |
| 6 min | ultra | 1.9-10.3 s | 120 of 120 | ~150 MB |
| 160 s | ultra | 1.2-1.9 s | 555 of 555 words of prose | ~150 MB |
| 76 s | tdt-v3 | 0.8-2.2 s | 24 of 24 | ~125 MB |

**Read the times as seconds, and not as ratios.** They move by a factor of five depending on what else the
machine is doing, which is why every verdict the script prints is about content rather than speed. Memory is
steady at 100-160 MB whatever the take's length, because the model lives on the Neural Engine rather than in the
app. Full tables, including the whisper numbers that justified removing it, are in
[`docs/measurements.md`](docs/measurements.md).

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
| Transcripts | `~/Documents/Ponte/note-<timestamp>.md` + rolling `all-notes.md` |
| Recordings | `~/Library/Application Support/Ponte/audio/` (deleted after use unless "Keep audio files" is on) |
| whisper models | `~/Library/Application Support/Ponte/models/` |
| Parakeet models | `~/Library/Application Support/FluidAudio/Models/` |
| Log | `~/Library/Application Support/Ponte/ponte.log` |

Each note records which engine produced it:

```yaml
---
date: 2026-10-21T23:50:37Z
duration: 8.5s
transcribe_time: 0.2s
engine: parakeet-ultra
---
```

## Updates

Ponte checks for its own updates with [Sparkle](https://sparkle-project.org). That is the **only** network request
the app makes, and it is worth being precise about what it contains:

| sent | not sent |
|---|---|
| a GET for `https://charlesponti.github.io/ponte/appcast.xml` | anything you have dictated |
| a User-Agent naming the app and version (`Ponte/1.0.1 Sparkle/2.x`) | your audio, transcripts, vocabulary, or usage |
| — | any account, key, or identifier |

The server sees an IP address and a time, as it would for any request. System profiling is off, so not even the OS
version or the machine model is sent. A failed check says nothing at all: no dialog, no error, no retry loop — a
laptop on a train should not be told about it. When an update *is* found, the menu's version line changes to say so,
because a background app that schedules checks has no other visible surface.

`--record` and `--transcribe` never start the updater, so the command line makes no request at all.

### What a release does now

1. `VERSION` holds the number; the build number is the commit count. Both are stamped by `build-app.sh`, which
   refuses to finish if the stamp did not take. **A version may never go backwards** — an updater reads the build
   number and would treat it as a downgrade.
2. `./scripts/build-app.sh --install` for a local build.
3. `./scripts/make-dmg.sh --notarize` for the signed, notarized, stapled DMG a first-time buyer downloads.
4. `./scripts/appcast.sh` packs the app into a zip, signs it with the EdDSA key in the login keychain
   (`SUPublicEDKey` in `Info.plist` is the other half), and writes `appcast.xml` for Pages to serve.
5. Attach `dist/Ponte-<version>.zip` **and** the DMG to the GitHub release, commit `appcast.xml`, and push.

The DMG is for people who do not have Ponte yet. The zip is what the updater installs.

## Vocabulary

Engines mis-hear the words that matter most: product names, colleagues, jargon. Ponte has two ways to fix that, and
they do different things.

**A replacement list**, which is what it ships with. Plain JSON, read at every transcription, so terms can be added
without a rebuild:

```
~/Library/Application Support/Ponte/vocabulary.json
```

```json
[ { "from": "parakeet", "to": "Parakeet" },
  { "from": "pin to",   "to": "Ponte" },
  { "from": "ponte app", "to": "the Ponte app" } ]
```

The menu item **Vocabulary: Edit Replacement List…** creates the file with two examples and opens it. Matching is
case-insensitive and whole-word — `ponte` does not fire inside `pontes` — and longer phrases are applied before
shorter ones, so a phrase rule wins over a single-word rule it contains. The replacement is literal: a `$` or a
backslash in a name is a character, not a template. A list that cannot be parsed means *no* replacements rather than
a failed dictation, because a broken list must never cost anyone their words.

It is applied once, where a transcript becomes final — so the note, the clipboard, the paste and the HUD's live line
all show the same text. `Ponte --transcribe file.wav` applies it too, which makes it the way to check a rule.

**Bias in the decoder**, which is not enabled. FluidAudio 0.17.7 does expose it —
`configureVocabularyBoosting(vocabulary:ctcModels:config:)` runs a *separate CTC model* over the same audio and
re-scores the transcript where the acoustics support a term, which is stronger than replacing text after the fact
because it can fix a word the engine got wrong in a way no spelling rule predicts. It costs an extra model (the CTC
checkpoint, about 98 MB), a second pass over the audio on every transcription, and it only helps terms the acoustics
are close to. The replacement list needs none of that and fixes the consistent errors — which is most of them.

## Permissions

- **Microphone** — required. Prompted on first recording; also under **Permissions ▸ Microphone**.
- **Accessibility** — only needed for auto-paste (sending ⌘V). Without it the transcript still lands
  on the clipboard and the HUD says "Copied to clipboard"; the app logs one quiet notice per launch
  rather than raising the system dialog at the end of every dictation. Grant it in
  **Permissions ▸ Accessibility**, restart, done.
- **Documents folder** — macOS asks the first time a note is written to `~/Documents/Ponte`.
  One grant, then it sticks (as long as the signature is stable). Move `AppPaths.transcripts` into
  `~/Library/Application Support/Ponte/` to avoid this prompt entirely.

After granting Accessibility, a restart usually makes it take effect — `AXIsProcessTrusted()` is cached
per launch. Not always: a fresh grant was picked up mid-session here, so try dictating before restarting.

### If the toggle is on but Ponte says it isn't granted

Grants are bound to the app's **code signature**, not to its name or its path, and an entry can sit
switched on in System Settings while applying to nothing at all. There is no prompt and no error in that
state — auto-paste just quietly becomes "Copied — press ⌘V".

Two things create it, and both are a change of signature:

- an **ad-hoc** signature (`--sign -`), whose requirement is a per-build hash that changes every build;
- alternating between an **Apple Development** and a **Developer ID** certificate, whose requirements
  differ by a field that the other does not carry — so grants die on every flip, each way.

**Fix:** Ponte icon ▸ **Permissions** ▸ **Repair permissions (clear a stale grant)**. It clears the dead
entry and asks macOS again, so the new grant binds to the build that is actually running. If that still
does not take, remove Ponte from the list with **−** and add `/Applications/Ponte.app` with **+**.

**For whoever builds this:** one identity, always. `scripts/build-app.sh` prefers the Developer ID
certificate for exactly this reason, `scripts/check-signature.sh` fails loudly when a requirement is not
team-anchored, and `make-dmg.sh` refuses to build a DMG that carries a per-build requirement. With a
single identity, every grant survives every future update — the requirement names the team, not the build.

## Menu

Four items, because everything else moved into the window:

- Start / Stop recording (shows the current hotkey), plus a state line while a take is in flight
- **Copy last transcript** · **Transcribe the last take again**
- **Open Ponte…** (⌘,) — the window: dictations first, then the settings
- **Quit Ponte** (⌘Q)

A found update adds one line here, because a menu-bar app has nowhere else visible to say it.

## The window

One window, opened with **⌘,** or *Open Ponte…*, and it is where everything lives:

| pane | what's in it |
|---|---|
| **Dictations** | every note in `~/Documents/Ponte`, searchable. Double-click copies; ⇧⌘C copies, ⌘↩ transcribes again, **Show note** opens the Markdown |
| **General** | hotkey (with a recorder), microphone, auto-paste, keep-audio, launch at login, and the vocabulary list |
| **Speech** | the model, whether it is downloaded, and the language |
| **Updates** | automatic checks, the last check, and the version |
| **About** | where the files are, and the two permissions with a repair that clears a stale grant |

The window refuses to open while a dictation is in flight, and says so in the HUD rather than in an error colour. A
window takes focus, and focus is where the paste goes: opening it mid-take would paste into itself. Every setting is
saved as you change it — there is no Save button, and a control that needs one is a worse control.

## Keys

| key | what it does |
|---|---|
| ⌥⌘Space (or whatever you set) | start a dictation; press it again to finish and paste |
| **Esc** | throw the take away — nothing is transcribed, no note is written, and the audio goes with it |
| **Return**, or the keypad's Enter | finish now, exactly as pressing the hotkey again does |

Esc and Return are heard **only while a dictation is in flight**. The HUD never takes focus — it must not, or
the letters you dictate would land in the HUD instead of the app you are writing in — so a bare key can only be
heard as a global hotkey: registered when recording starts, released the moment it ends. That window is deliberate.
A Return held down while idle would eat every return you press, in every app.

Cancelling shows a grey *Cancelled* pill — grey because nothing was pasted and nothing failed — and the
recording is deleted even if you have Keep audio files turned on: that setting is about dictations, and a cancelled
one is not going to become one.

## Setting the hotkey

**Open Ponte… → General → Record…**, then press the chord you want. Esc cancels. It applies immediately, without a
relaunch.

- A chord another app already owns is **refused with the reason**, and the old one is kept — a failed attempt never
  leaves you without a hotkey. The same is true if the registration fails at launch, which is logged.
- It needs ⌘, ⌥ or ⌃ (or a bare function key like F13). A plain letter is refused on purpose: a global hotkey on `A`
  would take `A` away from every application on the machine, and ⇧ alone does not help, because ⇧A is a capital A.
- While the recorder is open the current hotkey is unregistered, so pressing the chord you already have is captured
  instead of starting a dictation.

The two defaults still work, for a script or a fresh machine — but a change made with `defaults` needs a relaunch,
since the chord is registered at startup:

```bash
# ⌃⌥D = kVK_ANSI_D (2) with controlKey (4096) + optionKey (2048)
defaults write com.ponti.ponte hotKeyCode -int 2
defaults write com.ponti.ponte hotKeyMods -int 6144
```

Hex works too, if you'd rather read straight from a header: `-string 0x02` and `-string 0x1800`.

Back to the default ⌥⌘Space:

```bash
defaults delete com.ponti.ponte hotKeyCode
defaults delete com.ponti.ponte hotKeyMods
```

At launch, if another app already owns the chord, Ponte logs `hotkey registration failed`, posts a
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
Ponte --devices                              # list audio inputs, and where the speech model is
Ponte --download ultra                       # fetch + ANE-compile a Parakeet model
Ponte --bench take.wav                       # every installed model, 3 runs each, same file
Ponte --transcribe take.wav                  # uses the selected model (Ultra by default)
Ponte --transcribe take.wav --parakeet-model v3
Ponte --transcribe take.wav --engine whisper   # exits 2: there is one engine, and this says so
Ponte --selftest 5                           # record 5 s from the mic and transcribe it
Ponte --hud-strip hud.png                    # the HUD lifecycle as a contact sheet
Ponte --hud-render hud.png error 0.64        # one HUD frame at a moment in a state
```
