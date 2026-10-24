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
