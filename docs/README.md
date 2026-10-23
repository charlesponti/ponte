# Ponte — the docs

Ponte is push-to-talk dictation for macOS: press a hotkey, talk, text appears at your cursor. Everything
runs on the machine — no network calls, no account, no server. It is sold as a signed, notarized DMG from
the project's own website rather than through the App Store.

These documents are for whoever works on it next. They are not a tutorial: they record how the thing is
built, the numbers that were measured rather than assumed, and the mistakes that cost time, so the same
ground does not have to be walked twice.

## The set

| document | what it covers |
|---|---|
| [architecture.md](architecture.md) | the pipeline end to end, the modules, the settings and paths, and the shape of a dictation |
| [capture-and-engines.md](capture-and-engines.md) | recording, the two engines, what is shared with Waveform and Thames, and how to choose |
| [hud.md](hud.md) | the HUD's lifecycle, geometry, colours, and the orb's maths |
| [menu-bar-and-icons.md](menu-bar-and-icons.md) | the menu bar mark, the app icon, and the rules that keep both legible at 16 px |
| [permissions-and-signing.md](permissions-and-signing.md) | TCC, why grants die, the one-identity rule, and notarization |
| [measurements.md](measurements.md) | every number in this repository, with how it was taken |
| [testing-and-tooling.md](testing-and-tooling.md) | the test suites, the CLI's renderers, the scripts, and how to prove a change |
| [pitfalls.md](pitfalls.md) | the traps, each with the symptom it produced and the rule it left behind |
| [open-work.md](open-work.md) | the issue map, and what is waiting on a human |

## The five things worth knowing before touching anything

1. **Nothing leaves the machine, and that is a product promise, not a detail.** Adding a network call for
   telemetry, a licence check or an update check is a product decision, not an engineering one. See
   [open-work.md](open-work.md) for the two that are pending.
2. **The audio and the model are not in the app.** Recording goes through the shared `Waveform` package, and
   Parakeet runs on the Neural Engine with the app's own resident memory staying near 100 MB. Reading
   `Sources/Ponte/` alone will not tell you what the audio path does.
3. **A permission grant is bound to the code signature, not to the app's name.** Alternating signing
   identities kills every grant in both directions, silently. This has already cost a day once:
   [permissions-and-signing.md](permissions-and-signing.md).
4. **Measure the artifact that ships.** In-process renders of the orb are not reproducible; the same render
   through the command line is byte-identical every run. Three assertions in this repository were found
   passing on noise before that distinction was understood: [testing-and-tooling.md](testing-and-tooling.md).
5. **`ps %CPU` and the first line of `top -l` are lifetime averages.** They are not idle measurements, and
   one of them produced a bug report against an idle cost that did not exist: [pitfalls.md](pitfalls.md).

## How these documents are kept honest

- Every number here was measured on the machine described below, and [measurements.md](measurements.md) says
  how. Where something is *not* measured, it says so — "the boundary is unknown past six minutes" is worth
  more than a plausible figure.
- Where a claim is reproducible, the command that reproduces it is given. `./scripts/long-dictation-check.sh`
  exists precisely so the long-dictation numbers cannot drift into folklore.
- The design documents in [`design/`](../design/) are the specification for the HUD, not illustrations of it.
  Where a board and the code disagree, the board is right and the code is a bug.

## The machine these numbers come from

MacBook Pro, M1 Max, 32 GB, macOS 27.2, Xcode 27.1. Ponte requires macOS 15 or later. Parakeet models live
under FluidAudio's cache, not Ponte's; whisper models live under Ponte's own support directory. Both paths
are printed by `Ponte --help`.
