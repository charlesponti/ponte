# Testing and tooling

## The gate

```
swift build -c release          # the release build is the one that ships; test against it
swift test                      # the suite
./scripts/check-signature.sh /Applications/Ponte.app
./scripts/make-dmg.sh --install # install and smoke-test by hand
```

The suite is **62 tests** across nine files, plus `Probe.swift`, a measurement helper that is deliberately not a
test. `swift test` prints the count; it has been clean in repeated runs since the icon assertions were rewritten
(see below).

| file | covers |
|---|---|
| `HudLifecycleTests.swift` | the orb's geometry, colour and timings, frame by frame |
| `HudSpacingTests.swift` | ink clearance inside the box — orb above, label below |
| `IconTests.swift` | the icon marks: legibility invariants, sizes, the `.icns` inputs |
| `StatusIconTests.swift` | the menu bar mark is a template, centred, and 16 pt |
| `DictationKeyTests.swift` | Esc means cancel, Return means commit, and the key codes are right |
| `InputWatchTests.swift` | silence, quiet and healthy input buckets |
| `ReadinessTests.swift` | the readiness states, the percentage parser, and that labels fit the box |
| `SupportTests.swift` | hotkey parsing and describe, note frontmatter, small helpers |
| `Probe.swift` | render a HUD frame and measure its ink: `bright`, `brightShare`, `inkGroups` |

## What can and cannot be asserted

**Measure the artifact that ships.** In-process rendering of the orb is not reproducible — the same 512 px mark
ranged from 61 066 to 77 273 mint pixels across four runs, and its full-strength ink share from 0.165 to 0.460,
which overlaps the 16 px tile's 0.71-0.85. Three assertions were found "passing" on that noise before it was
understood. The same render through the command line is byte-identical (five runs, one hash), and the `.icns`
is built from the CLI. So:

- **Invariants may be asserted** in-process: sizes, centring, template-ness, that a state's tint is the colour
  it claims.
- **Shading and coverage may not.** Render them with `Ponte --icon` and read the numbers.
- Determinism in-process is tracked as `waveform#2`.

`Probe.inkGroups` is what lets a spacing test be a test: it renders a frame into an explicit `NSBitmapImageRep`
and reports the rows where ink starts and stops, so "the label has 18 pt below it" is a measurement rather than a
constant someone liked. Note that `ImageRenderer` runs at **1 px per point** in-process, not 2.

## The CLI is the honest renderer

```
Ponte --hud-render <out.png> <idle|recording|working|loading|done|error|cancelled> [t] [text] [colour] [--turning]
Ponte --hud-strip <out.png>       the lifecycle as a contact sheet
Ponte --hud-voice <out.png>       the orb answering a voice
Ponte --icon <out.png> <orb|halftone|ripple|core> [px]
Ponte --icon-sheet <out.png>      every mark at every size
Ponte --status-icon <out.png> [pt]
Ponte --status-image <out.png> <idle|starting|recording|working>
Ponte --bench <file.wav>          every installed engine on one file
Ponte --transcribe <file.wav> [--parakeet-model ultra|v3|v2|redux]
Ponte --record <seconds> [--out …] · --devices · --selftest · --download
```

Three things about it are deliberate. **It renders the real thing**, through the same code the app uses, so a
render and a screen capture can be compared. **It takes a colour and a `--turning` frame**, so a state can be
proofed in its true tint rather than the default one — the loading state's amber-versus-red mistake was only
visible once that was possible. And **its flags are refused when unknown**: anything the CLI does not recognise — a command, a flag, or a value
— exits 2 with an explanation rather than being ignored. A typo used to fall back to the default in silence,
which is how a table of timings came to carry a row that had run a different model. Removing an option is loud
for the same reason: `--engine whisper` now says so, instead of quietly transcribing with the only engine left.

## Measurement, in the right order

1. **Render** with the CLI, at the real size and the real colour.
2. **Measure** with Python: PIL and numpy, on an explicit `RGBA` conversion.
3. **Then** look at it, if looking is still needed.

ImageMagick is fine for one image and has twice collapsed a montage into something that was not the input —
its `+append` produced a 300x476 montage out of a five-cell row. Where every pixel matters, PIL is used instead.
Vision has also timed out on tall contact sheets, and once confidently identified macOS's own orange
microphone-in-use capsule as Ponte's menu bar mark: a crop at a stale position caught the wrong item, because
**the menu bar re-lays itself out when that capsule appears**. The item's frame is now logged per state so a
capture can be taken against a fresh position rather than a launch-time one.

A difference under about 15 % is not reliably visible. Measure it or say you cannot see it.

## Testing the live app

The tests cover the parts that can be reasoned about. The rest needs the app running, because the parts that
break live are permissions, the hotkey, the menu bar and the paste.

Useful method for a scripted dictation: `say` a sentence to the speakers while Ponte records through the
microphone. Three ways it lies to you, all of which have happened here:

- **The input device can be the wrong one.** AirPods connected as the default input record silence while `say`
  plays to the speakers. Check with `Ponte --devices` first; a take that returns nothing is more often this than
  a bug.
- **Too loud clips the take.** At full volume the recording peaked at 0.0 dBFS and the engine returned an empty
  transcript — the same sentence at a sane volume transcribed cleanly. `ffmpeg -i take.wav -af volumedetect -f
  null -` shows peaks and mean.
- **Silence and near-silence are different failures.** A device asleep measures −39 to −91 dBFS mean; real but
  unusable speech sits near −45 dBFS mean with peaks around −22. Two of the takes in the log were the second kind,
  and neither engine recovered them, at any gain.

The log (`~/Library/Application Support/Ponte/ponte.log`) records enough to tell these apart after the fact:
device, duration, engine, character count, confidence, and every state change.

## The scripts

| script | does |
|---|---|
| `build-app.sh` | assembles the `.app` — signs with the Apple Development certificate, which is fine for local use and is *not* what ships |
| `make-dmg.sh` | builds the DMG, signs it with Developer ID; `--notarize` submits it, `--install` copies the app to `/Applications` |
| `check-signature.sh` | fails unless a signed app carries a team-anchored requirement |
| `make-icon.sh` | renders every icon size through the CLI and assembles the `.icns` |
| `long-dictation-check.sh` | builds two synthetic materials — repeated sentences (seam-loss stress) and forty distinct sentences (the realistic case) — runs each engine over them, and fails any row that loses text, duplicates it, or ran the wrong engine |

## Verifying a change

1. `swift test` — and if the change touches the HUD's geometry or an icon, re-measure rather than trusting the
   constant that was edited.
2. Render the affected frame or mark with the CLI and read the numbers.
3. Install and use the app for the paths tests cannot reach.
4. `check-signature.sh` if signing was touched.
5. Write down what the measurement was. A number in a commit message is worth more than a paragraph of intent,
   and this repository's mistakes have been numbers that were never taken.
