# Measurements

Every number in this repository, with how it was taken and how to take it again. Where a figure is *not*
known, that is stated rather than estimated.

The machine: MacBook Pro, M1 Max, 32 GB, macOS 27.2. The microphone: the built-in one unless a line says
otherwise.

## Dictating, end to end

| what | value | how it was taken |
|---|---|---|
| hotkey → text at the cursor | ~0.5 s | earlier in the project, on a warm engine |
| stop → transcript, recent takes | 0.20-0.30 s for 7-9 s of speech | `ponte.log`: `transcribed 7.7s audio in 0.3s -> 51 chars` |
| first transcribe after a cold start | 6.7 s and 9.6 s, twice, on Oct 22 | the CoreML/ANE compile. Gone since the launch-time preload; every call since is under a second |
| engine throughput, one 8 s WAV | parakeet 0.14 s warm (56.8x), whisper 1.76 s warm (4.5x) | the project's original engine comparison, still in the README |

## Long dictations

whisper.cpp was the second engine until 1.0 and is gone; its rows below are kept because they are the numbers
that made Parakeet the default and then removed the alternative — see
[capture-and-engines.md](capture-and-engines.md) for why it went.

Reproduce with `./scripts/long-dictation-check.sh [work-dir]`. Synthetic speech: a sentence repeated N times
plus a closing marker, so a dropped region is countable. The script asserts the engine each run actually
reported, and fails a row whose repetitions or marker are wrong.

**Repetition material** — one sentence repeated N times plus a closing marker. A stress test for text going
missing at a seam, not a typical dictation.

| audio | engine | time | repetitions kept | closing marker | peak RSS | verdict |
|---|---|---|---|---|---|---|
| 20 s | parakeet-ultra | 0.91 s | 6 of 6 | intact | 105 MB | PASS |
| 76 s | parakeet-ultra | 0.66 s | 24 of 24 | intact | 122 MB | PASS |
| 6 min | parakeet-ultra | 1.85 s | **120 of 120** | intact | 149 MB | PASS |
| 76 s | parakeet-tdt-v3 | 1.04 s | 24 of 24 | intact | 128 MB | PASS |
| 76 s | whisper large-v3-turbo | 6.50 s | **6 of 24** | intact | 1895 MB | FAIL |

**Prose material** — forty distinct sentences plus a unique closing marker, judged by word count. This is the
material that resembles use, and the only one that can fairly judge an engine.

| audio | engine | time | words returned | closing marker | peak RSS | verdict |
|---|---|---|---|---|---|---|
| 160 s | parakeet-ultra | 1.92 s | 555 of 555 | intact | 151 MB | PASS |
| 160 s | whisper large-v3-turbo | 12.65 s | 566 of 555 (+2 %) | intact | 1950 MB | **PASS** |

Reading it:

- **Parakeet has no practical limit to six minutes**, and gets faster with length because the load cost
  amortises. Nothing truncated, nothing duplicated at the seams.
- **The boundary past six minutes is unknown.** Nothing has been tried beyond 371 s.
- **whisper is fine on long speech and fragile on repeated speech.** Six minutes of prose come back whole,
  ending included, within 2 % of the source word count. The same sentence twenty-four times in 76 seconds
  returns six of them, and a 26-second window holding eight repetitions returns two — so it is the repetition,
  not the length, and not the file: a second WAV encoder changed nothing, and neither did `-mc 0`, `-nf`,
  `-bs 1`, `-et 1.0`, `-et 0.0` or `-sns`. This was filed as "drops most of a long dictation" (#12) on the
  strength of the repetition rows alone, which was wrong about the cause.
- **Times are not ratios.** The same 6-minute row has measured 1.85 s, 2.14 s and 10.30 s; the same 76 s
  whisper row 4.29 s, 6.50 s and 17.77 s. Under load, it is a factor of five, not the "half" an earlier version
  of this paragraph claimed. Read them as seconds; the counts are what must not move.
- **A real take costs about five times a generated one.** The same release binary, the same engine, the same
  machine: 371 s of repeated synthetic speech transcribes in 1.87 s, and 360 s of a real dictation in 9.05 s
  (11.27 s on another run). The tables above are the right stress test for text going missing at a seam and
  the wrong material for pricing a live pass.

### What a live pass costs on real speech

`Ponte --transcribe` on a real take looped to length, release build, the engine's own elapsed count:

| audio | 60 s | 180 s | 360 s | 600 s |
|---|---|---|---|---|
| one pass | 1.9 s | 4.6 s | 9.1 s | 13.5 s |

Full investigation, with every measurement and the two false starts: [`live-transcript-lag.md`](live-transcript-lag.md).

Roughly **1.4 s of engine time per minute of audio**, linear in length. The live line waits twice the last
pass's cost (`LiveTranscript.interval`), so the preview's own lag is double the figure above: about 3 s at
30 s of audio, 9 s at three minutes, and 27 s at nine. That lag — not a round number of minutes — is what
the 180 s cap is really protecting, and why the 1.85 s row above must never be used to price the line.

## Idle cost

| what | value | how it was taken |
|---|---|---|
| CPU | **0.0 %** | `top -l 5 -s 3 -pid $PID`, reading the samples *after* the first |
| memory | 22 MB | same |
| threads | 4 | same |
| microphone-in-use pill | absent | screen-capture strip of the menu bar, counting orange pixels: 0 |
| bundle on disk | 20 MB | `du -sh /Applications/Ponte.app` |

`ps %CPU` and the first line of `top -l` report an average **since the process started**. An earlier version of
this measurement used them and reported 2.7 % "at idle" on a process that had just been transcribing — which
became issue #9, and was a measurement artifact rather than a cost. The method is in the README so it is not
repeated.

## The first run

| what | value |
|---|---|
| whisper models | base.en 148 MB, large-v3-turbo 1.5 GB |
| parakeet model, `ultra` | 603 MB on disk |
| parakeet model, `v3` | 461 MB |
| parakeet model, `redux` | 210 MB (2-bit weights; needs iOS 18 / macOS 15) |
| parakeet model, `ctc-110m` | 98 MB |
| silero VAD | 1 MB |
| one-time ANE compile | **46.4 s measured for v3**; ~23 s noted earlier for ultra. Cached per device afterwards |
| what the user sees | "Loading — 43 %" in the pill, and dictations declined with a reason rather than stalled |

## The HUD

Geometry, measured from the 2x renders the CLI writes, in points.

| | before | after |
|---|---|---|
| square box | 96 | **104** |
| clearance above the orb's ink | 15.0 | 15.0 (unmoved) |
| clearance below the label's ink | **10.0** | **18.0** |
| visible gap between orb ink and label | 15.5 | 15.5 |
| collapsed pill | 47 tall, 18.5 above / 19.0 below the text | unchanged |

The label's clearance was the complaint: the layout centres *frames*, and a frame is not what anyone sees. The
orb's 64 pt frame carries about 8 pt of dots too dim to register, top and bottom, and the label's frame carries
descender space its glyphs never use. `hudBlockLift` (default 4) is the knob; a test renders the frame and
measures the ink so the complaint cannot return by way of a constant that looks fine.

## The menu bar mark and the app icon

Five candidate marks, 18 pt render, judged from magnified crops of the true size. All five centre within 1 px
of their canvas, and all are template images so `contentTintColor` can colour them.

| mark | reads as | kept? |
|---|---|---|
| `coreRing` | a radio button | **yes — the default** |
| `orbEdge` | a blob | no |
| `pulseCore` | a record button | no |
| `speechDot` | a comma | no |
| `levelBars` | an audio meter | the closest runner-up |

`discRing` and `dottedRing` never shipped: a fine ring vanishes at 18 pt and a dotted ring becomes a fuzzy
halo. The same finding as the original dot-sphere glyph.

Icon marks, measured at 512 px and 16 px: brightness 0.81-0.89, 16 px coverage 17-50 %, all legible. The
halftone frame is 0.70 of the tile and the ripple's sphere 0.66.

### Why the icon's shading cannot be asserted in-process

| | 512 px mark | 16 px mark |
|---|---|---|
| full-strength ink, across four runs | **0.165 to 0.460** | 0.71 to 0.85 |
| mint pixels, across four runs | 61 066 to 77 273 | — |
| tenth-percentile brightness | 0.161 to 0.212 | 0.388 to 0.561 |

The 512 px render is not reproducible inside a test process — it depends on what ran before it — so assertions
about "the large one is shaded, the small one is flat" cannot be made from in-process measurements. **Through
the command line the same render is byte-identical** (five runs, one hash), and that is what writes the
`.icns`. The test suite therefore asserts only the invariants that held in every run, and the shading is
checked with `Ponte --icon /tmp/orb.png orb 512`. Making it measurable in-process is `waveform#2`.

## What the log says about real use

Mined from 18 launches and 26 recordings:

| | |
|---|---|
| input devices | 21 on the built-in microphone, 5 on AirPods |
| audio length | median 7.1 s, max 9.5 s |
| results | 14 reached an engine; 10 came back empty |
| — of those empties | **7 were silence** (−39 to −91 dBFS mean: an asleep input), **2 were speech too faint to use** (−45 and −49 dBFS mean, peaks −22.5 and −24.1), 1 was a clipped test |
| engines used | parakeet for all 14 |

Two results worth keeping: **35 % of attempts produced nothing usable**, which is what issue #11's mid-take
warning was built for; and the two faint takes were checked by hand — Parakeet returns nothing, whisper
returns a lone `.` and `-`, and gain-normalising them to −3 dBFS first changes neither. **No post-processing
recovers them**, which is why the answer is a warning during the take rather than a fix afterwards.

## The parse of that data

`ps %CPU`, the first line of `top -l`, and `top -l 2 … -n 1` are all lifetime averages. Two claims in this
project's history came from them and were wrong. Interval samples, or nothing.
