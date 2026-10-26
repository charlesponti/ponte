# Why the live transcript lags, measured

*Investigation, 26 October 2026. Machine: MacBook Pro M1 Max, 32 GB, macOS 27.2 (26B118), Xcode 27.1,
release build of Ponte built from `main`. Engine: `parakeet-ultra` (FluidAudio 0.17.7) on the Neural Engine.*

## What was asked

Whether the three-minute cap on the live transcript (`LiveTranscript.longestTake = 180`) is silly, given
that "six minutes only costs 1.85 s" — and whether it could be raised to twenty minutes instead.

The 1.85 s figure came from this repository's own `docs/measurements.md`. It is not what a live pass costs.
This document records how I found that out, every number taken on the way, and what it means for the
product. Two of my own numbers were wrong at first and one benchmark was measuring the wrong material; both
mistakes are below rather than tidied away, because the second one is the whole point.

## The complaint this explains

> "there is a perceptible lag in the words appearing as i talk which makes the product look broken right now
> even if i've only been talking for 10s"

That is correct, and it is not the three-minute cap. It is measurable at ten seconds.

## How a pass works, so the numbers mean something

`LiveTranscript` runs on a timer that ticks four times a second. When a pass is due it takes a snapshot of
the WAV **from the beginning of the take to now** and hands the whole thing to the engine. The next pass is
scheduled at `max(0.35 s, lastPassCost × 2)` — the wait is derived from what the pass cost, so the engine is
held at about half its capacity. The wait *is* the lag.

So the lag a person sees is roughly:

```
lag ≈ engine chunk latency + pass cost + wait (2 × pass cost)
```

Everything below measures the middle term.

## Method

All timings are the engine's own elapsed count, printed by `Ponte --transcribe <file>` as
`(<seconds>, engine=parakeet-ultra)`. That number starts *after* the models are loaded
(`ParakeetEngine.transcribe` takes its `started` timestamp after `preload`), so it excludes model load and
process start. Wall-clock figures quoted anywhere include both.

Audio for the long cases was made by looping one real dictation to length, so the content is real speech:

```sh
SRC=$(ls -S ~/Library/Application\ Support/Ponte/audio/*.wav | head -1)   # 15.98 s take
ffmpeg -stream_loop -1 -i "$SRC" -t <seconds> -ar 16000 -ac 1 -c:a pcm_s16le take.wav
swift build -c release
.build/release/Ponte --transcribe take-<seconds>.wav
```

## False start: the debug build cannot be used for timing

The first attempt used `.build/debug/Ponte`, which is `-Onone`. A **60-second** pass had not finished after
more than 100 seconds, and a background run was still working on the same 60 s file after roughly four
minutes. The model loaded in 0.5 s — the log shows `Loaded Encoder.mlmodelc with compute units:
cpuAndNeuralEngine` — so the cost was the Swift-side TDT decode loop, not the Neural Engine.

That is worth writing down for its own sake: **the debug binary is roughly two orders of magnitude slower at
transcription than the release binary.** A perceived-performance question must never be measured on it.
Everything below is `.build/release/Ponte`.

A second false start: `--bench` runs three passes over **every installed model**, so sweeping five lengths
through it exceeds a seven-minute tool budget even in release. `--transcribe` once per file is the cheap
equivalent.

## The curve: a real take costs ~1.4 s of engine time per minute

Release build, one pass over a looped real dictation:

| audio | engine time | per minute |
|---|---|---|
| 10 s | **0.57 s** | |
| 20 s | 0.82 s | |
| 30 s | 0.83 s | |
| 45 s | 1.18 s | |
| 60 s | 1.92 s | 1.9 s |
| 180 s | 4.57 s | 1.5 s |
| 360 s | 9.05 / 9.31 / 11.27 s | ~1.6 s |
| 600 s | 13.54 s | 1.4 s |

It is **linear**, about 1.4 s of engine time per minute of audio, with roughly ±20 % run-to-run spread
(the 360 s row was measured three times). Wall clock for the same runs was 1.96 / 4.59 / 9.34 / 13.55 s,
i.e. ~0.4 s more including process start and model load.

Extrapolating the fitted line: **twenty minutes of audio is a pass of about 28 s.**

## Why the repository's number disagrees

`docs/measurements.md` records `6 min | parakeet-ultra | 1.85 s`. Reproduced today with the repository's own
harness (`./scripts/long-dictation-check.sh /tmp/ponte-long`):

| run | audio | engine time |
|---|---|---|
| ultra-20s | 20 s | 0.56 s |
| ultra-76s | 76 s | 0.76 s |
| ultra-6min | 371 s | **1.95 s** |
| v3-76s (parakeet-tdt-v3) | 76 s | 0.78 s |
| ultra-prose | 160 s | 1.10 s |

So the table is reproducible — and so is my curve. They disagree because of **the material**, which the
decisive experiment shows: same binary, same engine, same machine, same length of audio.

```
/tmp/ponte-long/6min.wav   371 s, one sentence repeated   →   1.87 s
take-360.wav               360 s, a real dictation        →   9.05 s
```

**4.8× apart, entirely from the audio content.** The harness's repetition rows are one sentence repeated N
times plus a closing marker; that is a deliberate stress test for text going missing at a seam, and the file
says so. It is the wrong material for pricing a live pass. The harness's own prose row (forty distinct
sentences, 160 s → 1.10 s) is much closer to use, and still 2.4× faster than the looped real dictation at a
similar length — so the honest reading is that real dictation is *somewhere* between 1.10 s and 4.57 s per
160-180 s, and the conservative end is the one to design against.

`docs/measurements.md` already carried the warning that "times are not ratios" and that the same 6-minute row
has measured 1.85 s, 2.14 s and **10.30 s**. I read the headline and not the caveat, and told the user a
twenty-minute cap was plausible. The real-speech numbers are now recorded in that file too.

## What this means for lag at the lengths people actually use

Using `lag ≈ pass + 2 × pass` and ignoring engine chunk latency:

| take | pass | wait | lag ≈ |
|---|---|---|---|
| 10 s | 0.57 s | 1.14 s | **1.7 s** |
| 30 s | 0.83 s | 1.66 s | 2.5 s |
| 60 s | 1.92 s | 3.84 s | 5.8 s |
| 3 min (the cap) | 4.57 s | 9.14 s | 13.7 s |
| 20 min | ~28 s | ~56 s | ~84 s |

At ten seconds the line is already ~1.7 s behind the voice, which matches the reported experience. By three
minutes it is ~14 s behind; past that it stops entirely and says nothing. A twenty-minute cap would not
deliver twenty minutes of live text — it would deliver a line that advances about once a minute.

The `wait = 2 × cost` policy is the single largest term at every length. It was chosen to hold the engine at
half capacity; the comment in `LiveTranscript.swift` argues for it against a fixed 1.2 s interval, which was
worse. That may still be true, but it has never been tuned against a perceived-lag measurement.

## What the app cannot currently tell you

`ponte.log` from real dictations contains only `live transcript: watching <file>`. There is no per-pass line
recording cost, interval, or how many seconds of audio the line is showing. So a complaint like the one above
cannot be checked against a log, and a change to the throttle cannot be shown to have helped. Any fix should
add one line per pass:

```
live: pass took 0.57s over 10.2s audio — next in 1.14s, showing 9.8s
```

## The two fixes, in order of cost

**1. Tune the throttle (minutes).** `costMultiple = 2` is the biggest single contributor at short lengths. At
1.0 the ten-second lag falls from ~1.7 s to ~1.1 s; at 3 minutes from ~14 s to ~9 s. It doubles engine duty
from 50 % to 100 % during a live take, so it needs the per-pass log line to prove the final transcription
does not start late. Safer variant: keep the multiple for long takes, use a smaller one under ~20 s where the
pass is cheap.

**2. Windowed passes (the real fix).** Transcribe only the last ~30 s instead of the whole take, with
per-token timings (`UnifiedAsrManager.transcribeWithTimings`) to cut on a word boundary, appending only text
that is already stable. Cost per pass then becomes constant (~1 s at any length), lag stays flat, and
`longestTake` can be deleted rather than raised. This was attempted before and reverted pending token
timings; the timings are available in FluidAudio 0.17.7.

Neither is done yet. The doc correction is `210169d`.

## Caveats

- One machine, one engine, one OS build. Nothing here says anything about other hardware.
- The looped audio repeats a single 16 s take, so it is repetitive real speech — closer to use than one
  sentence repeated 24 times, less varied than forty distinct sentences.
- `Ponte.app` was running, idle, during the measurements. Thermal state was not controlled; the ±20 % spread
  is unexplained beyond "under load, it is a factor of five" as the measurements file already notes.
- Engine chunk latency was not measured, so every lag figure above is a lower bound.
