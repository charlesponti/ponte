# The menu bar mark and the app icon

Both are drawn from maths in `Icon.swift` rather than assembled from SF Symbols, because the app needed a mark
that reads at 18 pt *and* survives being a 1024 px icon, and no single symbol did both.

## The menu bar

The mark is drawn as a **template image** (`isTemplate = true`). That one flag is what makes it work on both a
light and a dark menu bar, and it is also what allows `contentTintColor` to colour it per state — a template
image is masked by its alpha, so any colour can be painted through it.

| state | glyph | tint |
|---|---|---|
| idle | the chosen mark | the system's own |
| starting | a record glyph | orange |
| recording | a record glyph | red |
| working | a waveform glyph | orange |

`StatusIcon.swift` is the single answer to "what is in the menu bar right now", used by the app and by
`Ponte --status-icon <out.png>`, so the two can be compared without a screen capture.

### Size

The mark rests at **16 pt** against the system symbols' 15 pt — deliberately smaller than it looks like it
should be, because **the item grew when recording**: a 18 pt mark made the status item's button jump from 32 to
34 px between states, and a menu bar item that resizes when you speak is visible. At 16 pt the button measures
32 px in both states.

Every mark is asserted **centred within one pixel** of its canvas. That test caught `levelBars` sitting 6.5 px
low at rest, because the group had been positioned for its tallest state instead of its resting one; the bars
now rest centred and grow upward.

### The seven marks

| mark | reads as | shipped |
|---|---|---|
| `coreRing` | a radio button | **the default** |
| `levelBars` | an audio meter — the only one that says "voice" | selectable |
| `pulseCore` | a record button | selectable |
| `speechDot` | a comma | selectable |
| `orbEdge` | a blob | selectable |
| `discRing` | a ring that vanishes at 18 pt | dropped |
| `dottedRing` | a fuzzy halo | dropped |

`levelBars` uses a bar width of 0.155 of the side, a gap of 0.115, and the cadence `[0.75, 1.0, 0.85]`. Choose
another with

```
defaults write com.ponti.ponte menuBarMark levelBars      # then relaunch
```

### The trap that produced the size rule

The first dot-composite mark rendered its dots **relative to the sphere**, which is correct at 512 px and
sub-pixel at 16 px: the peak landed at 0.50 against a 0.70 floor and the mark read as a smudge. Dots must be
sized against the **tile**, absolutely. The same mistake is available in the halftone icon frame, which is why
`IconRenderer` carries `dotScale(forTile:)` rather than a single scale factor.

## The app icon

Four marks, chosen by name: `orb` (the default), `halftone`, `ripple`, `core`.

- A 1024 canvas with an 824 pt squircle at radius 185, drawn as **ink on a transparent background** so macOS
  can apply its own shape and shading.
- `make-icon.sh` renders every size from 16 to 1024 through `--icon`, then assembles the `.icns`. The CLI path
  is the authoritative one: it is byte-identical run to run, where the in-process renderer is not
  ([measurements.md](measurements.md)).
- **Legibility at 16 px is the gate**, not beauty at 512 px. All four marks are legible at 16 px: brightness
  0.81-0.89 and 17-50 % coverage.

## Checking a mark

Numbers first, eyes second — a difference under about 15 % is not reliably visible, and the two have disagreed
before.

```
Ponte --icon /tmp/orb.png orb 16          # the real size, then magnified with nearest-neighbour
Ponte --icon-sheet /tmp/sheet.png         # every mark at every size
Ponte --status-icon /tmp/bar.png 18       # exactly what the menu bar gets
```

The suite covers what can be asserted (centring, template-ness, that the ink is where it is claimed to be) and
leaves taste to a human, because the one time a shade was asserted in-process it had to be backed out:
[pitfalls.md](pitfalls.md).
