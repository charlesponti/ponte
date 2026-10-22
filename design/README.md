# design/

Design artifacts for VoiceNote. **Nothing in here ships to the app** and nothing here rebuilds or
installs VoiceNote — it exists so a design can be agreed on before any code changes.

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
| `hud-directions.html` | The recording HUD: four directions (bar meter / quiet line / ribbon / dial), current state vocabulary, and the trade-offs. |

## Open questions

- HUD direction (A–D) — my read is **B** for daily use with **A** kept for error states.
- Whether the HUD should ever be repositionable, or stay bottom-centre.
- Whether to show a live partial transcript (streaming) instead of a level meter at all.
