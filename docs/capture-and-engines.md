# Capture and the engine

## Capture lives in the shared package

`Sources/Ponte/Recorder.swift` is a façade. The work happens in
`~/Developer/Waveform/Sources/WaveformCapture/EngineRecorder.swift`, shared with Thames, and it is
parameterised by `CaptureSettings`, not by app:

| setting | used by | what it produces |
|---|---|---|
| `.localTranscription` | Ponte | 16 kHz mono 16-bit WAV (`AVLinearPCMBitDepthKey: 16`) — exactly what Parakeet reads, so no conversion step exists |
| `.streamingSpeech` | Thames | the format its speech stack wants |

Two consequences:

- **Reading `Sources/Ponte/` will not tell you what the audio path does.** If a recording is the wrong shape,
  or ends early, the reason is in the package.
- **The package is a released dependency** (`github.com/charlesponti/waveform`, `from: "0.2.0"`). Changing
  the capture means a package release and a version bump here, not an edit in this repository.

### What the capture gives back

`ColumnRing` — 120 columns a second, ballistics applied: the level rises immediately and falls away over a
fraction of a second, so a voice's pitch does not make it flicker. Each `Column` carries `low`, `high`, `rms`
and `level`, all in **linear amplitude** (−1…1), not decibels. That matters: every threshold in this codebase
converts with `20 * log10`, the same conversion `Scale.decibels(floor:)` draws with.

`StreamClock` maps the audio's time onto the screen's, so the orb's picture moves smoothly between buffers
rather than stepping at buffer boundaries.

## The engine

Parakeet, through FluidAudio, on the Neural Engine. There is no other.

| | |
|---|---|
| runs as | CoreML on the ANE, `AsrManager` kept resident in-process |
| speed, 20-76 s of speech | 0.7-1.0 s (roughly 25-90x realtime) |
| speed, 6 minutes | 1.9-2.1 s — **faster with length**, because the load cost amortises |
| resident memory | 99-159 MB, regardless of take length |
| models on disk | `ultra` 603 MB (default), `v3` 461 MB, `redux` 210 MB, `v2` ~200 MB |
| long takes, prose | 555 of 555 words at 160 s; exact at six minutes with the closing sentence intact |
| repeated speech | exact: 120 of 120 repetitions at six minutes |
| first use | one-time CoreML compile for the ANE — 46.4 s measured for v3, minutes of wall clock in some cases. Cached per device afterwards |

Written into the note's frontmatter as `engine: parakeet…`, so a transcript can always be traced to the model
that produced it. The choice that remains is the model: `parakeetModel` (`ultra`/`v3`/`v2`/`redux`), set in the
**Speech model** submenu or with `--parakeet-model`. **Unknown values are refused** — they used to fall back
silently, which is how a table of timings came to carry a row that had run the wrong model.

## Why there is only one

whisper.cpp used to sit beside Parakeet as a selectable engine, and was removed. The reasons, in order of how
much they mattered:

1. **It needed a separate Homebrew install.** `whisper-cli` is not shipped with the app, so on a buyer's machine
   the Engine menu answered `whisper-cli not found (brew install whisper-cpp)`. That is a support ticket
   dressed as a feature, on an app sold from its own website.
2. **It was slower by an order of magnitude for no accuracy gain.** 4.4-17.8 s against 0.7-1.9 s on the same
   material, 1.9 GB resident against 150 MB, plus a 1.5 GB model download.
3. **It is fragile on repeated speech.** Six minutes of prose come back whole, but the same sentence twenty-four
   times in 76 seconds returns six — the decoder gives up on repetitive windows, and none of `-mc 0`, `-nf`,
   `-bs`, `-et` or `-sns`, nor a different WAV encoder, changes it. A dictation that repeats itself — a column
   of numbers, a list of part codes — could lose text, on a take of any length. Issue #12 filed this as a
   long-dictation bug; the material was the problem, and the finding stands either way.

The measurements it produced are kept here and in [measurements.md](measurements.md), because they are why
Parakeet is the default: without "1.76 s warm" beside "0.14 s warm", "fast" means nothing. Removing the option
is also loud rather than silent — `--engine whisper` exits 2 with an explanation, because an option that quietly
stops working is how the mislabelled row happened in the first place.

## Keeping the model warm

The engine is loaded once and kept resident (`ParakeetEngine.shared`), because a cold load costs seconds and a
CoreML compile costs tens of seconds. Three places manage this:

- **At launch** — `prepareEngine()` preloads silently if the model is on disk. This is why the first dictation
  is as fast as the second.
- **On a model change** — the same path runs, and because the model may not be on disk yet, it goes through
  `Readiness`: the app says "Loading — 43%" and **declines to start a dictation** until it can honour one,
  rather than recording a take and making the user wait on a 600 MB download.
- **Never on the recording path** — transcription never fetches anything if `Readiness` was honest.

`Readiness` is the gate for all three states: `ready`, `preparing(percent, note)`, `failed(message)`.

## Reading a transcript's quality

The log records `text=N chars confidence=C` for every take. Two patterns worth knowing:

- A **complete** take reports something like `confidence 0.99` or `1.00`.
- An **empty** take reports `text=0 chars confidence=0.10`. If you see that, the audio is almost always the
  problem, not the model: check the take's level with `ffmpeg -i file.wav -af volumedetect -f null -`.
  Silence from an asleep device measures −39 to −91 dBFS mean; speech too faint to use sits near −45 dBFS mean
  with peaks around −22.

That asymmetry is why `InputWatch` exists: it warns *during* a take that has heard nothing, because nothing
that runs afterwards can rescue it — [pitfalls.md](pitfalls.md) has the attempt that proved it.

## What a new engine would have to offer

Parakeet sets the bar at: one model file, under 700 MB on disk, under 160 MB resident, faster than realtime by
an order of magnitude, no network after download, and a clean boundary past six minutes. Anything added to the
Speech model menu should be measured through `./scripts/long-dictation-check.sh` first. It carries two
materials on purpose — repeated sentences, which catch text lost at a seam, and forty distinct sentences judged
by word count, which catch an engine that is unusable at length — and it checks the engine line of every run, so
a mislabelled row cannot pass.
