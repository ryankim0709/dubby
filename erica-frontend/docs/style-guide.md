# Dubby style guide

The visual system for the Dubby iOS app (SwiftUI, iOS 26). Every value here is defined in code; use the named tokens, not raw values. Source of truth: `Dubbing/Theme.swift`. When this document and the code disagree, the code wins: update this file.

Related: `docs/frontend-handoff.md` lists where backend data plugs into the UI.

## 1. The look in one paragraph

A dark screening room. Neutral charcoal with a soft grey glow behind the top-centre content, white for whatever is selected or tappable, grey for everything else. Imagery (posters, the scene video) carries the colour; the interface itself is monochrome. The only hues are functional: **red** while the microphone is recording, and **hologram cyan** for the character coach and tutor. Large rounded posters, bold system type, generous spacing. The app is **silent**: videos play muted, and the coach writes instead of speaking.

## 2. Colour

Use `Palette.<token>`. Never hard-code hex values in views.

| Token | Hex | Use |
|---|---|---|
| `background` | `#0F0F0F` | Screen base; solid bottom bars (`safeAreaInset`) so they blend with the gradient's edge |
| `backgroundGlow` | `#2C2C2C` | Centre of the screen glow (see §3); not used on its own |
| `surface` | `#1C1C1C` | Cards and panels: fact rows, waveform panel, coach panel, chat bubbles |
| `surfaceRaised` | `#2A2A2A` | Secondary buttons, icon wells, chips, a selected word's highlight |
| `hairline` | `#2C2C2C` | 1 pt separators between list rows |
| `track` | `#3A3A3A` | Inactive progress segments, page dots, empty waveform bars |
| `textPrimary` | `#F2F2F2` | Headings, body text, selected tab, active icons |
| `textSecondary` | `#9A9A9A` | Supporting text: source lines, captions, labels, the original actor's waveform |
| `placeholder` | `#7C7C7C` | Unselected tabs, hints, de-emphasised ranks, dotted underlines |
| `accent` | `#F2F2F2` | Primary button fill and selection marks (same white as `textPrimary`) |
| `onAccent` | `#0F0F0F` | Text and icons on `accent` fills |
| `record` | `#FF4D3D` | Only the record button, the live REC badge, and a reacted Feed flame |
| `holo` | `#6FF2FF` | Only the hologram coach and tutor: figure, beam, typed tip, practice-word highlights |
| `toggleOn` | `#34C759` | `Toggle` tint; a white track would hide the white knob |
| `shelfWood` / `shelfWoodShadow` | `#2E2E2E` / `#141414` | The Shelf plank gradient only |

Rules:
- **No brand accent colour.** Selection is white versus grey, never a hue.
- **Hues have one job each.** Don't use `record` for errors or warnings in general UI, and don't use `holo` outside the coach and tutor.
- Text on imagery sits on a scrim: `LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)` or a `MetaPill`.
- Contrast: body text ≥ 4.5:1. `textSecondary` and `placeholder` both pass on `background`; on `surfaceRaised`, use `textSecondary` or brighter.

## 3. Screen background

Every full screen calls `.screenBackground()`, never `.background(Palette.background)`.

```swift
ScrollView { … }
    .screenBackground()
```

`ScreenBackground` is `Palette.background` with a `RadialGradient` from `backgroundGlow` to `background`, centred at `UnitPoint(x: 0.5, y: 0.28)`, radius 0 → 460, ignoring safe areas. Exceptions:
- The **Feed** is pure black behind full-screen video.
- **Bottom action bars** pinned with `safeAreaInset(edge: .bottom)` use solid `Palette.background`.
- The **tutor takeover** adds a cyan glow on top: `RadialGradient(colors: [Palette.holo.opacity(0.14), .clear], center: UnitPoint(x: 0.5, y: 0.18), startRadius: 0, endRadius: 320)`.

## 4. Typography

Two faces, with strict roles.

**SF Pro (system) carries all interface text, headings included.** Always use `.dubFont(size, weight:)`. It scales with Dynamic Type through the nearest text style; don't use `.font(.system(size:))` for text.

| Role | Call | Example |
|---|---|---|
| Hero number (studio count-in) | `dubFont(84, weight: .heavy)` | 3 · 2 · 1 |
| Coach score | `dubFont(40, weight: .bold)` | 86 |
| Screen title | `dubFont(30–34, weight: .bold)` | That's a wrap, Choose your role |
| Detail-page title | `dubFont(32, weight: .bold)` | You underestimate my power |
| Section heading | `dubFont(24, weight: .bold)` | Most dubbed |
| Sub-heading / caption title | `dubFont(22, weight: .bold)` | Film name under the deck, tutor greeting |
| Current script line | `dubFont(26, weight: .bold)` | The line being dubbed |
| Button label | `dubFont(17, weight: .semibold)` | Built into the button styles |
| Body | `dubFont(17, weight: .regular)` | Synopsis |
| Row title | `dubFont(15–17, weight: .semibold)` | List rows, card titles |
| Supporting | `dubFont(14–16, weight: .regular/.medium)` | Source lines, translations, tips |
| Caption / label | `dubFont(12–13, weight: .semibold)` | "Line 2", "Timing", speaker names |
| Minimum | 11 pt | Badges only |

- Headings are **title case**, not all caps ("Most dubbed", not "MOST DUBBED").
- No kicker or eyebrow labels above headings; the heading speaks for itself.
- Numbers in counters and scores use `.monospacedDigit()`.

**League Gothic (condensed poster face) only where it imitates printed poster art:** titles printed on poster and DVD-case artwork, character names on role cards, and the **DUBBY** wordmark. Use `.displayFont(size)`; these are usually set `.uppercased()`. Never use it for headings, buttons, or body text.
- The file is `Dubbing/Fonts/LeagueGothic.ttf` (SIL OFL; licence beside it) and it's registered at launch by `DisplayFont.register()`. PostScript name: `LeagueGothic-Regular`.
- Wordmark: `Text("DUB\(Text("BY").foregroundStyle(Palette.textSecondary))").displayFont(30)`.

## 5. Shape and spacing

Corner radii (`Radius.<token>`):

| Token | Value | Use |
|---|---|---|
| `Radius.poster` | 22 | Deck posters, coach panel, large feature cards |
| `Radius.card` | 18 | Cards, panels, poster thumbnails, video frames, list cards |
| `Radius.control` | 16 | Buttons, icon wells |
| (literal) | 10 | Small list thumbnails |
| (literal) | 3–6 | DVD cases (3), word highlight chips (6) |
| `Capsule()` | — | Pills, badges, progress segments only |

Spacing:
- Page side margin: **20 pt** (the studio and dense panels use 16).
- Space between major sections: **32 pt**. Within a section: 12–16 pt. Inside cards: 16 pt padding.
- More space above a heading than below it.
- Touch targets ≥ **44 × 44 pt**.

Elevation: one shadow style, used on posters only: `.shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 14)`. Use either a border or a shadow, never both. Cards are flat `surface` fills.

## 6. Components

All in `Dubbing/Theme.swift` unless noted. Reuse these; don't restyle stock controls per screen.

| Component | What it is |
|---|---|
| `PrimaryButtonStyle()` | White fill, black semibold label, min height 52, full width, `Radius.control`. One per screen, for the main action |
| `SecondaryButtonStyle()` | `surfaceRaised` fill, white label, same size. "Not now", Retry, secondary actions |
| `MetaPill(text:systemImage:)` | Small capsule (`black` 45%) with white 13 pt semibold text, for metadata over imagery |
| `ArtworkView(artwork:)` | Poster or still: shows the asset `artwork.imageName` from Assets.xcassets, else the placeholder gradient |
| `AvatarView` / `AvatarStack` | Circular initials on a gradient; overlapping stack for co-dub credits |
| `ScreenBackground` / `.screenBackground()` | The charcoal glow (§3) |
| `GlossedLine` (`Dub/GlossedLine.swift`) | Script line with tappable words: dotted `placeholder` underline, a popover with the meaning |
| `FlowLayout` (`Dub/GlossedLine.swift`) | Wrapping row layout for word-by-word text |
| `HologramFigure` (`Dub/HologramCoachView.swift`) | The cyan projected character with beam, scanlines, flicker. Uses a `coach-<characterID>` asset if present |
| `SceneFacts`, `SceneCast` (`Discover/ScenePreviewSheet.swift`) | The facts row and cast list on scene pages |

Patterns:
- **Tabs inside a screen** (e.g. languages): plain text buttons, selected `textPrimary` semibold, others `placeholder` medium, 22 pt apart. No pills or underlines.
- **Page dots**: 6 pt dots in `track`; the current one becomes a 16 × 6 white capsule.
- **Ranked lists**: large rank number (`dubFont(34, weight: .heavy)`, first white, rest `placeholder`), 52 × 70 thumbnail, title and source, count on the right, `hairline` separators.
- **Switches**: `Toggle(...).tint(Palette.toggleOn)`.
- **App navigation**: the system `TabView` with Liquid Glass (Discover · Feed · Create · Inbox · Shelf), tinted white. Don't replace it with a custom bar.

## 7. Imagery

| Use | Aspect ratio |
|---|---|
| Deck poster, DVD case | 2 : 3 |
| Poster thumbnail card | 3 : 4 |
| Role card (character) | 3 : 4 |
| Scene video, studio stage | 16 : 9 |
| Detail-page hero | 4 : 5, edge to edge, fading into `background` at the bottom |

Asset names follow the sample data: `scene-<sceneID>` for scene posters, `character-<characterID>` for characters, `coach-<characterID>` for a cut-out of the coach figure. Until real art exists, `Artwork.placeholder` gradients stand in. Use only licensed or original imagery.

## 8. Motion

- **Thumbnail → detail page**: the iOS 18 zoom transition. Mark the thumbnail with `.zoomSource(id, in: namespace, cornerRadius:)` and push the destination with `.navigationTransition(.zoom(sourceID: id, in: namespace))`. Each source ID must be unique across the screen (prefix by section, e.g. `deck-`, `rank-`). Swipe down to go back.
- **Deck**: springs (`.spring(duration: 0.4–0.45, bounce: 0.15–0.18)`); cards behind the focused one scale by −13% per step and darken with a black overlay at 28% per step.
- **Coach and tutor text** types out at **40 characters per second** while the hologram "talks"; unrevealed text is laid out but clear, so nothing jumps.
- **Hologram**: 30 fps `TimelineView` for flicker, scan band, and talking pulse.
- **Reduce Motion**: every animated element checks `accessibilityReduceMotion`. Videos don't autoplay, typing shows the full text, and the hologram holds still. Keep this for anything new.
- Animate `transform` and `opacity`; no bouncy entrances on every element.

## 9. Sound

The app makes **no sound**. Every `AVPlayer` is muted, browse surfaces load picture only, and the coach and tutor communicate in text. The microphone still records takes, and the exported MP4 keeps full audio for sharing. Don't add playback audio, sound effects, or speech without a product decision.

## 10. Copy and naming

- The product is **Dubby**. Originals are labelled "Dubby Original".
- Buttons name their action: "Dub this scene", "Keep", "Retry", "Practice this line", "Continue to wrap".
- Errors say what happened and how to fix it ("Allow Dubby to add photos in Settings to save your dub.").
- Placeholder or sample data shown to users is labelled honestly. The tutor shows "Sample feedback · tutor service not connected" until real results arrive.

## 11. Accessibility checklist

- Text scales with Dynamic Type (`dubFont` / `displayFont` do this). Check at the largest accessibility size.
- Icon-only buttons have an `accessibilityLabel`; decorative images are `accessibilityHidden(true)`.
- Combine card contents into one element with `.accessibilityElement(children: .combine)` and a clear label.
- Contrast and 44 pt targets as above; respect Reduce Motion (§8).

## 12. Do and don't

Do:
- Use `Palette`, `Radius`, `dubFont`, `.screenBackground()`, and the button styles for every new screen.
- Let posters and video carry colour; keep the chrome monochrome.
- Put one white primary button per screen; everything else is secondary or text.

Don't:
- Introduce a new accent colour, gradient text, or glassmorphism beyond the system tab and navigation bars.
- Use League Gothic for interface text.
- Nest cards, or add borders and shadows together.
- Use emoji as icons; use SF Symbols.
- Hard-code colours, radii, or font sizes outside these tokens.
