# Open work

The GitHub issues are the source of truth for what is left. This document exists to say which ones matter, which
are waiting on a person, and what is known but not filed.

## Filed

Fifteen issues were filed together after the first phase of measurement, deliberately lowest-priority-first so
the list reads top-down as a work order. Repositories: `charlesponti/ponte-macos` and
`charlesponti/waveform-ios`.

### Closed

| | what it was | how it was settled |
|---|---|---|
| #11 | warn while dictating when the input is silent or too quiet | `InputWatch`: −20 dBFS peaks are "quiet", −39 dBFS and below is "dead", sampled 4x a second |
| #10 | first run should warm the engine and fetch the model behind a visible state | `Readiness`: warm at launch, decline a dictation with a reason rather than stall behind a 600 MB download |
| #9 | measure and cut idle cost | measured: 0.0 % CPU, 22 MB, 4 threads. The 2.7 % in the issue was `ps %CPU`'s lifetime average. No work to do, and the method is now written down |
| #8 | long dictations at 30 s / 2 min / 10 min | Parakeet is fine to six minutes and gets faster with length; whisper drops most of a long take → filed as #12. Boundary past six minutes: untested |

### Open

| | what | notes |
|---|---|---|
| **#12** | whisper silently drops most of a long dictation | **closed as not the bug it looked like, and whisper itself removed.** Whisper is fine on long prose (566 of 555 words at 160 s, whole) and collapses on *repetition* — 6 of 24. The test material was one sentence 120 times, which is pathological for its decoder. No chunking: a 26-second chunk still loses three quarters. The limitation is now documented, and the check script carries a prose row |
| #7 | notarize the DMG | blocked: needs the account holder to create the `ponte-notary` credential profile |
| #6 | ship an update path | an appcast is a network call on a schedule — a product decision, not a technical one |
| #5 | show the transcript in the HUD while speaking | party trick that costs the watch-the-orb honesty |
| #4 | local history window | search and re-copy past dictations |
| #3 | custom vocabulary | names and jargon that engines keep missing |
| #2 | re-transcribe a failed take from the menu | the audio is kept after a failure for exactly this |
| #1 | decide the licence-check service, and what it costs the "no network calls" promise | blocked: waiting on research. A licence check would be Ponte's first network call |
| waveform-ios#2 | make the orb's render independent of ambient graphics state | upstream: in-process renders vary, so some assertions have to be made through the CLI |

## Waiting on a human

- **Notary credentials.** `xcrun notarytool store-credentials ponte-notary --apple-id … --team-id 3QHJ2KN8AL
  --password …` has to be run by the account holder once. The password should not pass through a script or an
  agent, which is why it is not automated.
- **The licence question.** Ponte currently makes **zero network calls**; that is the product's pitch. Any
  commerce integration is either offline (a signed licence file, verified locally) or it breaks the pitch.
  The licence candidates named so far — Paddle, Lemon Squeezy, Gumroad — were *not* assessed.
- **The menu bar mark, by eye.** Its presence in the real bar has never been confirmed visually; captures were
  inconclusive and the crop caught macOS's own microphone capsule. The mark is correct in the renderer and
  template-tagged, but "does it read well in your bar" is a question for the person looking at the bar.

## Known, not filed

- **The boundary past six minutes is unknown.** Six minutes is measured; ten is not. Nothing suggests a cliff,
  because Parakeet gets faster with length, but it has not been tried.
- **Ten minutes is not the same as ten minutes of speech at 16 kHz.** The test material is synthetic and
  uniform; real speech has silence, breathing and background noise. The failure mode to look for is a long
  silence mid-take, not length.
- **Ponte on iOS is parked.** The models build for iOS (`FluidAudio` declares `.iOS(.v17)` and compiles), but iOS
  has no global hotkey, and Apple's keyboard-extension rules forbid microphone access outright while capping a
  keyboard at roughly 60-70 MB resident — less than the smallest model. The established pattern is a hand-off
  to a containing app. Nothing is planned.
- **`Thames`' `CLAUDE.md` has one stale line.** The edit was blocked as a protected agent-instruction file and
  not retried.
- **~5 GB of `.build` directories** sit in the three checkouts. Deliberate; they make the next build quick.

## Deliberately not doing

Recorded so they are not rediscovered as good ideas:

- **Cloud sync, accounts, telemetry.** Out on principle, and the pitch depends on it.
- **Adding another engine, or a fallback between them.** Parakeet is faster than realtime by an order of
  magnitude and accurate; a second engine means a second install path, a second model download and a second set
  of failure modes, for a comparison nobody using the app needs. If one is ever added, it has to earn its place
  through `long-dictation-check.sh`, which measures both materials and checks which engine ran.
- **Shipping whisper.cpp as an option.** Removed in this change; it needed a Homebrew install, so the menu item
  was broken on any machine without one. Its numbers stay in the docs as the reason Parakeet is the default.
- **Per-app paste rules, silence auto-stop, audio ducking.** Each adds a state the user has to understand, to
  solve a problem the HUD and the hotkey mostly solve.
- **Payment handling.** Use a merchant of record, preferring offline verification.

## If you are picking this up

Start with **#12**: it is a silent data-loss bug in a shipped menu item, it has a reproduction, and the fix has
a clear acceptance test. Then #2 and #4, which are small and make failures recoverable. #7 unblocks the release
properly once someone with the Apple account creates the credential profile.
