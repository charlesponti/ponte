# design/

Design artifacts for Ponte. **Nothing in here ships to the app** and nothing here rebuilds or
installs Ponte — it exists so a design can be agreed on before any code changes.

## How we work

1. I write a self-contained HTML artifact here and preview it in the chat.
2. You react — click a direction in the artifact, or just say what's wrong with it.
3. I iterate on the *artifact*, never the app, until you approve a direction.
4. Only then do I change `Sources/` and rebuild. One implementation pass, on an agreed design.
5. Major revisions are preserved as new files (`hud-directions v2.html`) so we can walk back.

## Rules the artifacts follow

- **Real metrics.** Sizes, radii, insets, states and timings are lifted from the Swift source, not
  invented, so what you approve is what builds. Each file says which source it came from.
- **Honest context.** Mockups are shown over a simulated backdrop (dark editor / light document /
  mid grey) because the HUD is translucent — it only reads truthfully against content.
- **1× by default.** Panels are drawn at true pixel size; use the scale tweak only to double-check
  the small ones.
- **Clicks come back to me.** Buttons carry `data-hermes-send`, so choosing a direction sends me a
  message rather than just changing pixels.

## Files

| File | What it decides |
|---|---|
| `hud-directions.html` | Direction board: four HUD shapes (bar meter / quiet line / ribbon / dial). **Decided: B.** Kept as the record. |
| `hud-b.html` | B alone, with the Waveform orb in the waiting state. Four orb sizes at true size — **decided: 64 px orb**. |
| `hud-b-lifecycle.html` | Orb lifecycle v1: recording spins fast, working calm, done fades green, error throbs red three times. |
| `hud-b-lifecycle-v2.html` | Orb lifecycle v2: the **box collapses with the orb** — done ends at text + 16 px padding, error holds through the throbs then collapses as the orb exits. |
| `site-studio-v2.html` | Full public-site redesign study: centered product demo, honest trust details, problem-led story, FAQs and repeated download action. |

## Open questions

- Recording spin rate — board offers 2× / 4× / 7× of the model's 0.35 rad/s; currently 4×.
- Does *working* keep spinning fast, or drop to the model's calm rate? (currently calm)
- The collapsed pill ends wider than tall (96 × 96 → 118 × 47). That is what “text + 16 px all round”
  gives you; more vertical padding would keep it squarer.
- Whether the HUD should ever be repositionable, or stay bottom-centre.
- Whether to show a live partial transcript (streaming) instead of an orb at all.

## settings-window.html

The window's directions (A: sidebar + panes, B: ledger + inspector, C: command-first), built at the real
860 × 560 against this Mac's own dictations. **A was chosen and built.**

The board shows the pre-Liquid-Glass look: an opaque window with a flush sidebar. The shipped window keeps the same
layout but the sidebar is now a floating glass panel on macOS 26+. The material cannot be drawn in a board (or in an
`ImageRenderer` still) — it samples what is behind the window — so `docs/glass.md` records the research and the
running app is the only place to judge it.
