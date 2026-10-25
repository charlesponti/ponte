# Liquid Glass on macOS 27, and what Ponte does with it

Research notes for making the window use the macOS 26/27 material. Everything below is checked against the SDK on
this machine (MacOSX27.0.sdk) or quoted from Apple's *Adopting Liquid Glass*.

## What actually exists

| API | module | since | notes |
|---|---|---|---|
| `NSGlassEffectView` | AppKit | **macOS 26.0** | `contentView`, `cornerRadius`, `tintColor`, `style` |
| `NSGlassEffectView.Style` | AppKit | 26.0 | `.regular`, `.clear` |
| `effectIsInteractive` | AppKit | **macOS 27.0** | visual response to interaction; default `NO` |
| `NSGlassEffectContainerView` | AppKit | 26.0 | merges nearby glass views; `spacing` |
| `View.glassEffect(_:in:)` | **SwiftUICore** | 26.0 | `glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape())` |
| `Glass` | SwiftUICore | 26.0 | `.regular`, `.clear`, `.identity`, `.tint(_:)`, `.interactive(_:)` |
| `GlassEffectContainer` | SwiftUICore | 26.0 | `init(spacing: CGFloat? = nil)` |
| `glassEffectID(_:in:)`, `glassEffectUnion(id:namespace:)` | SwiftUICore | 26.0 | morphing/merging between shapes |
| `GlassEffectTransition` | SwiftUICore | 26.0 | `.matchedGeometry`, `.materialize`, `.identity` |
| `GlassButtonStyle` / `.glassProminent` | SwiftUI | 26.0 | button styles that adopt the material |

**A gotcha worth remembering:** `glassEffect` and `Glass` are in **SwiftUICore**, not SwiftUI. Grepping
`SwiftUI.framework`'s interface for `glassEffect` returns nothing and reads exactly like "SwiftUI has no glass API" —
which is wrong. Check both modules.

Availability is **26.0**, not 27.0, for everything except `effectIsInteractive`. Ponte's package floor is macOS 15, so
every use must be behind `if #available(macOS 26.0, *)` with the opaque look as the fallback.

## What Apple says to do with it

Quoted from *Adopting Liquid Glass*:

- "Liquid Glass applies to the **topmost layer** of the interface, where you define your navigation."
- "Key navigation elements like tab bars and **sidebars float in this Liquid Glass layer** to help people focus on
  the underlying content."
- "Ensure that you **clearly separate your content from navigation elements**, like tab bars and sidebars, to establish
  a distinct functional layer above the content layer."
- "Be judicious with your use of color in controls and navigation so they stay legible."
- "Optimize for legibility when content scrolls beneath controls." (scroll edge effect)
- "Windows adopt **rounder corners** to fit controls and navigation elements."

That is the whole design brief: **glass is navigation, content stays solid.** A window that is glass edge to edge is
the one thing the guidance argues against, and it is also what makes text unreadable over a busy desktop.

## Therefore: what Ponte does

The approved layout is already the right shape — sidebar on the left, content on the right. Glass goes on the
sidebar and nowhere else:

1. **The sidebar becomes a floating glass panel** — inset from the window edges, rounded, `.regular` with
   `.interactive()` because it is clickable, drawn by `.glassEffect(_:in:)` on macOS 26+.
2. **The content pane keeps its solid surface.** The dictations list, the settings rows and every value stay on
   `#131315` so text contrast does not depend on the wallpaper.
3. **The window becomes see-through** — otherwise the glass has nothing to sample and renders as flat grey:
   `isOpaque = false`, `backgroundColor = .clear`, `titlebarAppearsTransparent = true`, and `.fullSizeContentView` so
   the glass can reach the top edge under the traffic lights.
4. **Dark appearance, explicitly.** `NSAppearance(named: .darkAqua)` on the window, so the glass resolves dark on a
   light desktop too. Ponte is a dark app; a light glass sidebar next to a dark content pane would read as a bug.
5. **Room for the traffic lights.** With a full-size content view they float over the sidebar, so the sidebar's first
   row starts below them (~30 pt), and the window title is hidden — Apple's own Settings does the same.
6. **Corners stay the system's.** A titled window already rounds to the current convention ("rounder corners" in 26);
   the root view is clipped so an opaque content pane cannot square them off.

## Why not a SwiftUI `App`/`Window` scene

Glass does not require one. `glassEffect` is a view modifier, and `NSGlassEffectView` is a plain view; both work inside
the `NSHostingView` this app already has. A scene rewrite would fight the CLI modes (`--record`, `--transcribe`,
`--settings-render`) that live in top-level `main.swift`, for no visual gain. What glass *does* need is a translucent
window, which an `NSWindow` does as well as a SwiftUI scene does.

## What can and cannot be verified

- **Can:** that the code path ran (a log line naming the glass mode and the OS version), that the window reports
  `isOpaque == false` and a clear background, that geometry and layout are unchanged (the sidebar is inset, so the
  content pane is narrower — measure it), and that the 129 tests still pass.
- **Cannot:** the appearance itself. `ImageRenderer` does not render the material (it draws the same flat placeholder
  class of output as it does for `ScrollView`), and screen capture is blocked in this environment. The material has to
  be looked at in the running app.

## Sources

- SDK: `AppKit.framework/Headers/NSGlassEffectView.h`; `SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/*.swiftinterface`
- Apple: *Adopting Liquid Glass* (`developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass`)
- Apple: `NSGlassEffectView`, `Glass`, `GlassEffectContainer` reference pages
