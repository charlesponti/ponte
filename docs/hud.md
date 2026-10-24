# The HUD

The HUD is the app's one surface: a borderless floating panel at the bottom of the screen, hosting a SwiftUI
box. It appears when a dictation starts and leaves when the outcome has been read.

**The boards in [`design/`](../design/) are the specification.** `hud-b-lifecycle-v2.html` is the current one;
`hud-directions.html` and `hud-b.html` are the earlier explorations, kept because they record what was
rejected and why. Where a board and the code disagree, the board is right.

## The lifecycle

| state | tint | spin | orb scale | label | box | hides at |
|---|---|---|---|---|---|---|
| `recording` | mint | 1.4 rad/s (4x base) | 100 % | a live `m:ss` clock | 104 square | never — it ends with the take |
| `working` | mint | 0.35 | 100 % | `…` | 104 square | never |
| `loading` | grey | 0.9, clockwise | 100 % | `43%`, or `Loading — 43%` when a dictation was declined | 104 square | never |
| `done` | mint → green | ramps down | 100 % → fade | `Pasted ✓`, `Copied — press ⌘V`, `Ready ✓` | collapses to the pill | 1.40 s |
| `cancelled` | mint → grey | ramps down | 100 % → fade | `Cancelled` | collapses to the pill | 1.10 s |
| `error` | mint → red | ramps down | 100 % → 82 %, throbs to 94 % | `Heard nothing`, `Not ready`, … | holds, then collapses | 3.00 s |

Durations: done holds its colour 0.15 s and collapses over 0.55 s. Error takes 0.18 s to change colour,
0.25 s to shrink, then three throbs at 0.42 s each peaking +12 %, then collapses over 0.46 s. Cancelled is the
same collapse as done, quieter and sooner (0.10 s and 0.42 s).

**The box.** 104 pt square while recording, radius 26, collapsing to a pill sized *text + 16 pt on all four
sides*. The label is 10 pt in the square and 12.5 pt in the pill. The orb is 64 pt.

## Colours

| name | value | used for |
|---|---|---|
| mint | `#66d4cf` | recording, working — "the microphone is live" |
| green | `#32d74b` | a successful paste |
| red | `#ff453a` | a failure |
| grey | `#8E8E93` | the loading orb, the cancelled orb |
| amber | `#FFD60A` | the input watcher's warning |
| blue-grey | `#8B9AA8` | the loading label |

The box is black at 94 % rather than the usual `.hudWindow` material: the orb's outer dots are drawn at 18 %
and vanish against a grey blur. A 12 % hairline is the only edge.

## The rules behind it

- **One glanceable fact per pill.** `Pasted ✓`, `Cancelled`, `Check the mic`. Two numbers with an arrow between
  them was tried and reads as a puzzle.
- **The HUD never takes the keyboard focus.** If it could, the letters being dictated would land in the HUD
  instead of the app being written in. This is why Esc and Return are global hotkeys held only during a take
  ([architecture.md](architecture.md)).
- **Colour lands before movement.** A state change is understood from its colour first, so the tint changes
  immediately and the geometry follows.
- **The box collapses with the orb**, not after it: the done state ends at text plus 16 pt, not an empty square.
- **A warning is not a failure.** The input watcher and the loading state use amber and grey; red is reserved
  for things that actually went wrong. An early version showed a red, throbbing "Getting ready" for a download,
  which is a lie about what happened.
- **Labels must fit the box.** About sixteen characters at the smallest label size — 86 pt of ink inside a
  104 pt box, measured. Longer text draws outside the squircle. This has bitten twice; there is a test.
- **The orb's visible ink is smaller than its frame.** The 64 pt frame carries roughly 8 pt of dots too dim to
  register top and bottom, which is why spacing that looks right in the code is not. See
  [measurements.md](measurements.md) for the ink measurements.

## The live transcript

While a take is running the box is wide — **330 × 156** — and a row sits under the orb: the clock on the left, one
line of speech filling the rest. Words arrive out of a blur, the line drifts left as each one lands, and the oldest
slide off behind a 34 pt fade. Nothing scrolls and nothing wraps.

### The words are metered, not dumped

The engine does not deliver words at the rate they are spoken. It transcribes everything it has heard each time it
is asked, so a burst of three or four words arrives together every 1.2 s. Animating the burst animates the wrong
thing: you would see the transcript arrive in lumps, which is a property of polling rather than of speech.

So words are queued and released at the rate they were *spoken*, measured from the take itself — words ÷ seconds of
audio, clamped to 2–6 a second. A slow speaker gets slow words; a fast one keeps up.

The blur is then derived rather than chosen. A word's entrance should occupy about two thirds of its slot:

| symbol | meaning | value |
|---|---|---|
| `R` | words a second, measured | 2.5 — conversational English, 150 wpm |
| `1/R` | the slot each word gets | 400 ms |
| `D` | how long a word takes to resolve | `clamp(0.72/R, 0.15, 0.40)` → **288 ms** |

The bounds are perceptual, not stylistic: under about 150 ms the eye reads a cut rather than a blur, and past
400 ms a word is still resolving when the next one lands, which is a permanent haze rather than a reveal. Past
about 4.8 words a second the floor takes over from the rule, which is why there is a clamp at each end and a test
for each.

Because the schedule is arithmetic on a queue, it is asserted rather than watched (`TranscriptRevealTests`): a
burst of seven words drains in 2.688 s, every word resolves inside its own slot, and the newest one or two sit at
66 % ink until a later snapshot agrees with them. That last part is honest about a real property — each snapshot
re-transcribes the audio, so the tail *can* change. A word that looks final but moves reads as a mistake; one that
looks provisional reads as thinking.

### Reading a file that is still being written

A WAV in progress has **zero in its two size fields** — the recorder fills them in when it closes the file — and
the engine refuses it outright: *"Invalid audio data provided. Must be at least 300ms of 16kHz audio."* So a pass
copies the bytes written so far and patches the RIFF size and the `data` chunk size. The first version wrote the
`data` size *into the first two samples* instead of into the field four bytes before them, which the engine would
have heard as a click; the header test is what stopped it.

Only one pass may be in flight. The engine is shared with the final transcription, and a queue of passes would
delay the result the person is waiting for, so a tick that finds a pass running is skipped. The interval starts at
1.2 s, stretches to 2 s past twenty seconds, and stops entirely past a minute: the engine's cost grows with the
audio (0.59 s for eight seconds, about 2.5 s for two minutes) and the line is a courtesy by then. `live.stop()`
runs *before* the final transcription is asked for.

Measured on real speech, fed to the live path one second at a time: passes over 1.0, 2.0, 3.0, 4.0 and 5.34 s of a
take still being written, each costing **0.15–0.18 s**, with no pass losing a word an earlier one had, and the
first word settled from the first pass onwards.

### The panel has to hold the box

The floating panel is a fixed size, and the box is drawn inside it. It was 420 × 132 — sized for a 104 pt square —
while the live box is 330 × 156, so the top of the box fell outside the panel and the orb was cut off. It is
420 × 180 now, and `HudPanelTests` asserts that every state's box and the longest label the HUD can say both fit.

The reason this is worth a test rather than an eye: a clipped box is invisible in the one place you would look for
it. Rendering the box alone says nothing about whether the panel is big enough to show it, and neither does a test
of the geometry — the box was drawing correctly the whole time it was being cut off.

### Working on it

- `--hud-demo [seconds]` shows the real HUD panel — same panel, view, state machine and reveal — driven by a
  scripted take. This is how to see the live transcript on a machine whose default input is a pair of AirPods, and
  how it was verified on screen: the box complete, the clock running, an older word fading at the left, and the
  newest arriving out of a blur.
- `--hud-render <out.png> recording <t> <text> --words "the quick brown fox" --since 2 --rate 2.5` draws the live
  box at any moment. The reveal is a function of time, so the same arguments always draw the same frame.
- `--record 12 --live` runs the whole thing against the microphone and prints what it hears while the take is still
  running, with the elapsed time of each pass. This is how the feature is exercised without a GUI.
- The acoustic route is unavailable on a Mac whose default input is a pair of AirPods: scripted dictation needs the
  speakers to reach the microphone. `LiveTranscriptIntegrationTests` gets around it by synthesising speech to a
  *file* (`say -o`, no microphone involved) and feeding it in slices — the same shape of input the recorder gives
  the live path.
- A run-loop `Timer` will not do this job. It fires only when something is running the run loop, and there are real
  cases where nothing is — while a menu is tracking, and in any harness that pumps the main queue without spinning
  the run loop. It is a `DispatchSourceTimer`, whose handler hops to the main queue so everything stateful stays
  single-threaded.
- **Never ask `AVAudioFile` how long a file being written is.** It reports zero for a WAV whose size fields are
  zero, so a guard built on it silently blocks every pass. The only trustworthy measure mid-take is the payload:
  16 kHz mono 16-bit is 32,000 bytes a second.

## The orb

From `WaveformUI`, the same sphere Thames draws: 1,100 dots, a gain of 0.25 and a dot scale of 0.28 at Ponte's
64 pt, a voice floor of −55 dBFS and 0.8 s of history across the sphere. The engine's columns carry linear
amplitude, and the view maps them through `Scale.decibels`.

**Which way it turns.** The projection places a dot at

```
x1 = u.x * cos(spin) + u.z * sin(spin)
```

so a dot on the front equator — `u = (0, 0, 1)` — lands at `sin(spin)`. **A positive rate carries the visible
surface to the right**, which is the direction a clock's hand travels across the top of its dial, and that is
the way every state turns. There is no in-plane rotation to reverse: the sphere spins about its vertical axis
like a globe, so "clockwise" here means the front surface drifting right.

**Why the spin cannot be measured from stills.** The dots are a golden spiral, deliberately free of clusters
and rows, so two frames of a rotating orb differ by the *same* amount at any speed, and a slowmotion render
looks much like a fast one. The rate is a judgement — 0.35 reads as a faint shimmer, 1.4 is what the app uses
to say "spins fast" while recording, and loading sits at 0.9 — and it is tunable by eye:

```
defaults write com.ponti.ponte hudLoadingSpin -float 1.2
```

## Working on it

Render any frame at 2x, in its real colour, turning or still:

```
Ponte --hud-render /tmp/frame.png loading 0 "Loading — 43%" blue-grey
Ponte --hud-render /tmp/moving.png recording 1.5 --turning
Ponte --hud-strip /tmp/strip.png        # the whole lifecycle as a contact sheet
Ponte --hud-voice /tmp/voice.png        # the orb answering a voice
```

[`testing-and-tooling.md`](testing-and-tooling.md) covers the rest, including the ink-profiling helper the
spacing test uses.
