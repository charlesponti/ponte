# Capture and engines

## Capture lives in the shared package

`Sources/Ponte/Recorder.swift` is a façade. The work happens in
`~/Developer/Waveform/Sources/WaveformCapture/EngineRecorder.swift`, shared with Thames, and it is
parameterised by `CaptureSettings`, not by app:

| setting | used by | what it produces |
|---|---|---|
| `.localTranscription` | Ponte | 16 kHz mono 16-bit WAV (`AVLinearPCMBitDepthKey: 16`) — exactly what whisper.cpp and Parakeet read, so no conversion step exists |
| `.streamingSpeech` | Thames | the format its speech stack wants |

Two consequences:

- **Reading `Sources/Ponte/` will not tell you what the audio path does.** If a recording is the wrong shape,
  or ends early, the reason is in the package.
- **The package is a released dependency** (`github.com/charlesponti/waveform-ios`, `from: "0.2.0"`). Changing
  the capture means a package release and a version bump here, not an edit in this repository.

### What the engine gives back

`ColumnRing` — 120 columns a second, ballistics applied: the level rises immediately and falls away over a
fraction of a second, so a voice's pitch does not make it flicker. Each `Column` carries `low`, `high`, `rms`
and `level`, all in **linear amplitude** (−1…1), not decibels. That matters: every threshold in this codebase
converts with `20 * log10`, the same conversion `Scale.decibels(floor:)` draws with.

`StreamClock` maps the audio's time onto the screen's, so the orb's picture moves smoothly between buffers
rather than stepping at buffer boundaries.

## The two engines

| | parakeet (`ultra` by default) | whisper (`large-v3-turbo`) |
|---|---|---|
| runs as | FluidAudio → CoreML, **on the Neural Engine** | a `whisper-cli` subprocess |
| speed, 20-76 s of speech | 0.7-0.9 s (roughly 25-90x realtime) | 4.4-9.2 s |
| speed, 6 minutes | 2.1 s — **faster with length**, because the load cost amortises | not usable, see below |
| resident memory | 99-147 MB | 1886-1895 MB |
| model on disk | 603 MB (`ultra`), 461 MB (v3), 210 MB (redux), 98 MB (110m) | 1.5 GB (large-v3-turbo), 148 MB (base.en) |
| long takes | 119 of 120 repetitions at six minutes, nothing truncated | **6 of 24 repetitions at 76 seconds** |
| first use | one-time CoreML compile for the ANE: 46.4 s measured for v3, ~23 s noted earlier for ultra, cached afterwards | loads weights and runs |

**Parakeet is the engine; whisper is a reference point.** Whisper is kept because it is the benchmark every
other number is quoted against, and because a second engine is useful when a result looks wrong. It should not
be the engine anyone dictates through until issue **#12** is fixed: on a 76-second recording it returns the
first 19 seconds and the closing sentence, silently dropping everything between. The Engine menu offers it, so
a user can hit this.

Set with `engine` (`parakeet`/`whisper`) and `parakeetModel` (`ultra`/`v3`/`ultra`-family). The CLI's flags are
`--engine` and `--parakeet-model`, and **unknown values are refused** — they used to fall back silently, which
is how a table of timings came to carry a row that had run the wrong model.

## Keeping the model warm

The engine is loaded once and kept resident (`ParakeetEngine.shared`), because a cold load costs seconds and a
CoreML compile costs tens of seconds. Three places manage this:

- **At launch** — `prepareEngine()` preloads silently if the model is on disk. This is why the first dictation
  is as fast as the second.
- **On a model or engine change** — the same path runs, and because the model may not be on disk yet, it goes
  through `Readiness`: the app says "Loading — 43%" and **declines to start a dictation** until it can honour
  one, rather than recording a take and making the user wait on a 600 MB download.
- **Never on the recording path** — transcription never fetches anything if `Readiness` was honest.

`Readiness` is the gate for all three states: `ready`, `preparing(percent, note)`, `failed(message)`.

## Reading a transcript's quality

The log records `text=N chars confidence=C` for every take. Two patterns worth knowing:

- A **complete** take reports something like `confidence 0.99` or `1.00`.
- An **empty** take reports `text=0 chars confidence=0.10`. If you see that, the audio is almost always the
  problem, not the model: check the take's level with `ffmpeg -i file.wav -af volumedetect -f null -`.
  Silence from an asleep device measures −39 to −91 dBFS mean; speech too faint for either engine sits near
  −45 dBFS mean with peaks around −22.

That asymmetry is why `InputWatch` exists: it warns *during* a take that has heard nothing, because nothing
that runs afterwards can rescue it — [pitfalls.md](pitfalls.md) has the attempt that proved it.

## What a new engine would have to offer

Parakeet sets the bar at: one model file, under 700 MB on disk, under 150 MB resident, faster than realtime by
an order of magnitude, no network after download, and a clean boundary past six minutes. Anything added to the
Engine menu should be measured through `./scripts/long-dictation-check.sh` first — it counts repetitions, so a
silent loss of half the audio cannot pass as a good result.
