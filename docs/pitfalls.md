# Pitfalls

Things that cost time here, in the shape they cost it in. Each one has a symptom, a cause, and a rule. None of
them are obvious from reading the code they live in.

## Measuring

**Symptom.** Ponte reports 2.7 % CPU at idle, and an issue is filed about a cost that does not exist.
**Cause.** `ps %CPU` and the first line of `top -l` report an average **since the process started**. The process
had been transcribing a minute earlier.
**Rule.** Interval samples only — `top -l 5 -s 3 -pid …`, reading the samples after the first. A measurement
taken the wrong way is worse than no measurement, because it gets written down.

**Symptom.** An icon test passes, then fails, then passes, on unchanged code.
**Cause.** In-process rendering of the orb is not reproducible: the same 512 px mark ranged over 61 066-77 273
mint pixels and 0.165-0.460 ink share across four runs, overlapping the 16 px tile's range. Two "structural"
assertions were sitting inside that overlap.
**Rule.** Assert invariants in-process and measure shading through the CLI, which is byte-identical run to run.
Do not assert a statistic whose spread you have not measured.

**Symptom.** A crop proves the layout changed — the panel is 1040 px wide and clearly shows the desktop.
**Cause.** The capture was 1040 px wide. The crop was the whole screen.
**Rule.** Check a crop's extent before believing what it shows. Twice here, a "composite" contained a bogus
panel that was not the app.

**Symptom.** A montage of five images comes out as a 300x476 single panel.
**Cause.** ImageMagick's `+append`, which did the same thing twice.
**Rule.** Where every pixel matters, use PIL with an explicit `RGBA` conversion. Also: ImageMagick's RGB parsing
alpha-silently mis-measures sheet cells.

**Symptom.** A render is different every time it is run, and `lockFocus` is involved.
**Cause.** `lockFocus` and friends pick up ambient graphics state.
**Rule.** Render into an explicit `NSBitmapImageRep`. And know that `ImageRenderer` runs at **1 px per point**
in-process, not 2 — the CLI renders at 2x, which is why the CLI is the one to trust for size.

## The menu bar

**Symptom.** A screen capture at the item's reported position shows `<<` chevrons, and vision identifies an
orange capsule.
**Cause.** macOS adds its own microphone-in-use capsule to the menu bar and **re-lays out the bar when it
appears**, so the frame captured at launch is stale. The orange capsule was macOS's, not Ponte's, and the crop
had caught the wrong item.
**Rule.** Log the status item's frame per state, and take a capture against the fresh position. Never trust a
frame measured at launch.

**Symptom.** The menu bar item changes width when a dictation starts.
**Cause.** The resting mark was 18 pt, so the item's button jumped from 32 to 34 px between states.
**Rule.** Size the mark against the *tallest* neighbour and check the button width in both states. It now rests
at 16 pt and measures 32 px either way.

**Symptom.** A mark that looks good at 512 px is a smudge at 16 px: its brightest pixels reach 0.50 against a
0.70 floor.
**Cause.** The mark's dots were scaled with the sphere. At 16 px they were sub-pixel.
**Rule.** Size dots against the **tile**, absolutely. This has now bitten twice — the sphere glyph and the
halftone icon frame — which is why `IconRenderer` has `dotScale(forTile:)`.

**Symptom.** A mark renders in the bottom-left quadrant at half size.
**Cause.** Drawing in pixel coordinates into a canvas sized in points.
**Rule.** Multiply by the scale factor, or draw in one coordinate system and convert once.

**Symptom.** `levelBars` sits 6.5 px low at rest.
**Cause.** The group was positioned for its tallest state rather than its resting one.
**Rule.** Rest centred and grow outward. Assert centring to within a pixel — that test is what found it.

## The HUD

**Symptom.** The label looks cramped under the orb, and the measurement agrees: 10 pt below the label's ink
against 15 pt above the orb's.
**Cause.** The layout centres *frames*. The orb's 64 pt frame carries about 8 pt of dots too dim to register,
and a text frame carries descender space its glyphs never use.
**Rule.** Measure ink, not frames. `hudBlockLift` is the knob, and a test measures the rendered frame so the
constant cannot quietly drift back.

**Symptom.** A first-run download is shown in red, throbbing, as though something failed.
**Cause.** The refusal reused the error state, because "cannot dictate right now" was modelled as an error.
**Rule.** Amber for "not ready yet", grey for "cancelling", red for "this went wrong". A download is the app
doing what it said it would.

**Symptom.** A percentage reads 234 %.
**Cause.** `percent(in:)` matched the last three digits of `1234%`.
**Rule.** Anchor the pattern — `(?<!\d)(\d{1,3})%` — and let the test be the spec. The test caught this bug in
the code that was written to fix the previous one.

## The test material can be the bug

**Symptom.** Whisper returns 6 of 24 repetitions from a 76-second recording, and an issue is filed saying it
silently drops most of a long dictation. Two subsequent controls contradict it: 27 seconds of prose come back
65 of 66 words, and six minutes of prose come back whole with the closing sentence intact.
**Cause.** The material was one sentence repeated 120 times. Long stretches of identical audio are a known
weakness of Whisper's decoder — it decodes a few repetitions and gives up on the window. The measurement was
correct and the conclusion drawn from it was wrong: the variable that mattered was repetition, not length.
**Rule.** Before concluding "it fails at long input", vary the content and hold the length fixed. A synthetic
material that is easy to count is not the same as a realistic one, and the countable property can be the thing
being measured. The check script now carries both materials, labelled.

## A tool that deletes beside its input

**Symptom.** A measurement script's source text disappears part-way through its own table, and the row that
needs it fails with "No such file or directory".
**Cause.** The app's whisper path ran `whisper-cli -otxt -of <wav-without-extension>` and then deleted that
sidecar after reading it. The script's `prose.txt` sat beside `prose.wav` and was collateral damage. (That path
has since been removed along with whisper; the rule outlives it.)
**Rule.** Write temporary files somewhere disposable — `FileManager.default.temporaryDirectory` — never beside
an input whose name you did not choose. A CLI that can delete a file in the user's directory because of what
the *input* is called is a bug whatever the file is for.

## A release can pass its own check and fail a buyer's

**Symptom.** Notarization is Accepted, the staple validates, the build prints `accepted, source=Notarized
Developer ID` — and `spctl -a -t open --context context:primary-signature` on the **DMG** says `rejected, source=no
usable signature`. The app inside has no staple either.
**Cause.** The build signed the *app* and submitted the *image*, which is enough to be accepted and not enough to
ship. Gatekeeper assesses the disk image when a buyer opens the download, and an unsigned image fails on its own
signature; stapling only the image leaves the app inside without a ticket of its own.
**Rule.** Assess the artifact the buyer touches, and not the one you built. Sign the disk image as well as the
app, notarize and staple both, and run the check against the DMG — ideally against a quarantine-tagged copy,
which is what a browser download actually is. A build that reports its own success in its own words is not
evidence.

## Editing this codebase

**Symptom.** A one-line addition to the CLI's usage text fails the build with *"insufficient indentation of
line in multi-line string literal"*, and the line named in the error is nowhere near the code that was edited.
**Cause.** The usage text is a Swift multi-line string, and every line in it must be indented at least as far as
its closing delimiter. Two lines were pasted in with the indentation of the shell session they came from.
**Rule.** Before patching a multi-line string literal, read the block and match its common indentation. The
compiler's line number points at the first under-indented line, which may be hundreds of lines from the edit.

## Audio and engines

**Symptom.** A scripted dictation returns an empty transcript, and the engine is blamed.
**Cause.** Two different things, both the test's fault: AirPods were the default input device, so the microphone
recorded silence while `say` played to the speakers; and at full volume the take clipped at 0.0 dBFS, which
produces nothing at all.
**Rule.** Check `Ponte --devices` first, keep the speakers at a sane level, and check a take's peaks with
`ffmpeg … -af volumedetect` before concluding anything about the engine.

**Symptom.** Real speech produces nothing, from either engine, at any gain.
**Cause.** Speech far below the usable range: −45 dBFS mean with peaks near −22. Gain-normalising to −3 dBFS
first does not help; the information is not there.
**Rule.** Warn during the take rather than trying to rescue the file afterwards. This is why `InputWatch`
exists, and it is the most common way a dictation produces nothing: 35 % of the takes in the log.

**Symptom.** The first transcription after launch takes 6.7 s, or 9.6 s.
**Cause.** The CoreML/ANE compile for the model, paid once per device.
**Rule.** Preload at launch behind a visible readiness state. Never load on the recording path.

**Symptom.** A row in a table of engine timings claims a model that never ran.
**Cause.** `--engine parakeet-v3` is not an engine — v3 is a *model* — and the CLI silently fell back to the
default. The measurement was of ultra wearing v3's name.
**Rule.** A tool must refuse what it does not understand, flags included. The CLI now exits 2 on an unknown flag
or value, with the list of what it does accept, and `long-dictation-check.sh` asserts the engine each run
reported. Removing the `--engine` option entirely was done the same way: loudly, with an error that says what to
use instead. A silently ignored option turns into a confidently wrong measurement.

## Saying what happened

**Symptom.** A summary implies a feature was verified when only its pieces were.
**Cause.** The menu bar mark's presence in the real bar was never confirmed by eye: captures were inconclusive,
and an A/B against the app being quit differed by less than the bar's own noise. Vision's read of a crop was
macOS's capsule.
**Rule.** Say which claims were measured, which were inferred, and which are still unverified — and name the
person who can settle it. "The user's eyes are the oracle" is a legitimate answer; a confident guess is not.

**Symptom.** An issue is reported as closed, and is still open.
**Cause.** `gh issue close` failed on shell quoting; the command looked like it had worked.
**Rule.** Verify external state by reading it back — `gh issue view` — rather than trusting the exit code of the
write. This applies to pushes, releases and uploads too.
