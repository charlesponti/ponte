# Architecture

## The shape of one dictation

```
  ⌥⌘Space (Carbon hotkey, or the menu)
        │
        ├─ Readiness gate ── not ready? say so in the pill, decline, stop.   [Readiness.swift]
        │
        ├─ Microphone permission (asked once, first launch)
        │
        ├─ Recorder.start() ── EngineRecorder(.localTranscription)           [Recorder.swift]
        │                     16 kHz mono WAV, written to AppPaths.audio
        │                     while recording: InputWatch samples the level 4x/s
        │                     and Esc/Return are grabbed as hotkeys          [InputWatch, DictationKeys]
        │
        ├─ Stop: ⌥⌘Space again, Return, or Esc (cancel)
        │
        ├─ AsrEngine.transcribe(wav:) on a background queue                  [ParakeetEngine.swift]
        │       parakeet → FluidAudio → CoreML, on the Neural Engine
        │       whisper  → whisper.cpp CLI, a reference point only
        │
        └─ finish()                                                          [AppDelegate.swift]
                write the note (~/Documents/Ponte, frontmatter carries engine + timings)
                load the transcript onto the clipboard, always
                auto-paste with a synthesised ⌘V if Accessibility is granted
                show one pill — "Pasted ✓" or "Copied — press ⌘V"
                delete the audio unless Keep audio files is on
```

Everything between the hotkey and the paste is bounded by two things worth remembering: **the HUD must never
take the keyboard focus** (if it did, the letters being dictated would land in the HUD instead of the app
being written in), and **the app must not make a network call** (the models are fetched on first run, which
is the only time the app touches the network at all — see `Readiness`).

## Modules

| file | lines | what lives there |
|---|---:|---|
| `AppDelegate.swift` | 870 | the app's spine: menu bar, hotkey handling, the recording lifecycle, the menu, permissions, the model and engine switches |
| `main.swift` | 644 | the CLI — flag parsing, the renderers, and the helpers the tests use (`hudImage`, `voiceRing`) |
| `ParakeetEngine.swift` | 346 | FluidAudio's `AsrManager` kept resident, model download/load, `AsrEngine` dispatch, `Whisper` discovery |
| `Icon.swift` | 318 | the app icon's four marks and the menu bar's five, drawn from maths rather than borrowed from SF Symbols |
| `Orb.swift` | 259 | `HudSpec` (every colour and duration), `HudLifecycle` (geometry and colour per frame), `HudState` |
| `Support.swift` | 215 | `AppPaths`, `Settings`, `SettingKey`, logging, notifications, the whisper model list |
| `Transcriber.swift` | 185 | the note format (markdown with frontmatter), `ModelDownloader` for whisper models |
| `HUD.swift` | 136 | the panel, `show*` entry points, the hide timer |
| `HudView.swift` | 105 | the SwiftUI box and the live view that ticks it |
| `Recorder.swift` | 99 | Ponte's façade over `WaveformCapture.EngineRecorder` |
| `HotKey.swift` | 96 | the Carbon hotkey wrapper and `HotKeySpec.describe` |
| `InputWatch.swift` | 62 | "is the microphone hearing anything" |
| `Readiness.swift` | 60 | whether dictation can start, and what to say when it cannot |
| `DictationKeys.swift` | 52 | Esc and Return, and what each one means |
| `StatusIcon.swift` | 42 | what the menu bar wears in each state |

## Dependencies

Two, deliberately — an app whose pitch is "everything on device" should be readable.

- **`Waveform`** (`github.com/charlesponti/waveform-ios`, released, `from: "0.2.0"`) — `WaveformCore` for the
  column maths and `WaveformUI` for the orb. **The audio capture comes from here too**: `Recorder.swift` is a
  façade over `WaveformCapture.EngineRecorder`, shared with Thames. Reading `Sources/Ponte/` will not tell you
  what the capture path does; see [capture-and-engines.md](capture-and-engines.md).
- **`FluidAudio`** — Parakeet's CoreML models and `AsrManager`. Its models are cached under
  `~/Library/Application Support/FluidAudio/Models`, which is why a "fresh install" is not the same as a
  deleted Ponte support directory. The models are MIT/Apache 2.0.

## State

Three pieces of state, each with one job:

- **`AppState`** (`StatusIcon.swift`) — `idle | starting | recording | working`. Drives the menu bar glyph and
  the menu's first line, and is the gate the hotkey reads.
- **`Readiness`** (`Readiness.swift`) — `ready | preparing(percent, note) | failed(message)`. Whether the
  engine's models are on disk and loaded. Set at launch and on every engine or model change. While it is not
  `.ready`, a dictation is **declined with a reason** rather than recorded and made to wait.
- **`HudState`** (`Orb.swift`) — `idle | recording | working | loading | done | error | cancelled`. Drives the
  HUD's geometry and colour; `HudLifecycle` is pure in `t`, so any frame can be rendered or tested.

## Settings

Read through `Settings`, backed by `UserDefaults`, registered in `Support.registerDefaults()`.

| key | default | meaning |
|---|---|---|
| `engine` | `parakeet` | which engine transcribes |
| `parakeetModel` | `ultra` | `ultra`, `v3`, `v2`, `redux` |
| `model` | `ggml-large-v3-turbo.bin` | the whisper model, only used by the whisper engine |
| `language` | `en` | passed to the engine as a hint |
| `autoPaste` | `true` | paste at the cursor, or leave it on the clipboard |
| `keepAudio` | `false` | keep the WAV after a successful dictation |
| `hotKeyCode` / `hotKeyMods` | 49 / 2304 | ⌥⌘Space |

Three more keys are read but not shown in the menu, for tuning without a rebuild:

| key | default | meaning |
|---|---|---|
| `menuBarMark` | `coreRing` | which of the seven menu bar marks to wear (`Icon.swift`) |
| `hudBlockLift` | `4` | points the orb-and-label block is lifted inside the square box |
| `hudLoadingSpin` | `0.9` | radians a second for the loading orb's rotation |

```
defaults write com.ponti.ponte hudLoadingSpin -float 1.2     # then start a dictation
```

## Paths

| what | where |
|---|---|
| notes | `~/Documents/Ponte` — one markdown file per dictation, frontmatter carries engine, elapsed audio and transcription time |
| audio | `~/Library/Application Support/Ponte/audio` — kept only when `keepAudio` is on, and after a failed or empty take so it can be diagnosed |
| whisper models | `~/Library/Application Support/Ponte/models` |
| parakeet models | `~/Library/Application Support/FluidAudio/Models` |
| log | `~/Library/Application Support/Ponte/ponte.log` — every state change, and the numbers behind each |

The log is the first place to look when something is wrong. It records the device a recording came from, the
duration, the engine, the character count, the confidence, every readiness change, every input-watch verdict,
and where the notes went.

## Threading

- The main actor owns the HUD, the menu bar item, and all of `HudLifecycle`. Rendering onto the main actor
  and *measuring* off it is what the CLI's renderers rely on — see [testing-and-tooling.md](testing-and-tooling.md).
- Transcription runs on a background queue; only the result crosses back.
- The engine load is guarded so a launch-time preload and a dictation cannot race: one `loadTask` at a time,
  keyed by model (`ParakeetEngine.asrManager(for:progress:)`).
- The input watcher samples at 4 Hz on the main run loop, added in `.common` mode so it keeps ticking while a
  menu is open.

## Adding a HUD state

Seven entry points, in this order — the compiler names the ones you forgot:

1. `HudState` in `Orb.swift`.
2. `HudLifecycle.visual(_:_:)` — tint, spin, orb scale and alpha as a function of `t`.
3. `HudLifecycle.geometry` if the box collapses differently, and `lifetime` if it hides itself.
4. `HUD.swift` — a `show*` method, passing the label's colour at the call site.
5. `defaultHudText(for:)` and `hudColour(for:)` in `main.swift`, so the CLI can render it.
6. `HudLifecycleTests` or a new suite, asserting the frame.
7. Render it: `Ponte --hud-render /tmp/x.png <state> 0 "Label" [colour]`.
