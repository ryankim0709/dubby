---
name: Dubby
description: Erica's screening-room system for the native dubbing app
colors:
  background: "#0F0F0F"
  background-glow: "#2C2C2C"
  surface: "#1C1C1C"
  surface-raised: "#2A2A2A"
  hairline: "#2C2C2C"
  track: "#3A3A3A"
  text-primary: "#F2F2F2"
  text-secondary: "#9A9A9A"
  placeholder: "#7C7C7C"
  accent: "#F2F2F2"
  on-accent: "#0F0F0F"
  record: "#FF4D3D"
  holo: "#6FF2FF"
  toggle-on: "#34C759"
typography:
  wordmark:
    fontFamily: "League Gothic"
    fontSize: "30pt"
    fontWeight: 400
  poster:
    fontFamily: "League Gothic"
    fontSize: "36pt"
    fontWeight: 400
  headline:
    fontFamily: "SF Pro"
    fontSize: "32pt"
    fontWeight: 700
  section:
    fontFamily: "SF Pro"
    fontSize: "24pt"
    fontWeight: 700
  title:
    fontFamily: "SF Pro"
    fontSize: "22pt"
    fontWeight: 700
  script:
    fontFamily: "SF Pro"
    fontSize: "26pt"
    fontWeight: 700
  body:
    fontFamily: "SF Pro"
    fontSize: "17pt"
    fontWeight: 400
  button:
    fontFamily: "SF Pro"
    fontSize: "17pt"
    fontWeight: 600
  supporting:
    fontFamily: "SF Pro"
    fontSize: "14pt"
    fontWeight: 400
  label:
    fontFamily: "SF Pro"
    fontSize: "13pt"
    fontWeight: 600
rounded:
  poster: "22pt"
  card: "18pt"
  control: "16pt"
spacing:
  compact: "8pt"
  inner: "12pt"
  content: "16pt"
  page: "20pt"
  section: "32pt"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
    typography: "{typography.button}"
    rounded: "{rounded.control}"
    height: "52pt"
    width: "100%"
  button-secondary:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.text-primary}"
    typography: "{typography.button}"
    rounded: "{rounded.control}"
    height: "48pt"
  surface-card:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.card}"
  metadata-pill:
    backgroundColor: "rgba(0, 0, 0, 0.45)"
    textColor: "{colors.text-primary}"
    typography: "{typography.label}"
    height: "26pt"
---

# Design System: Dubby

## Overview

**Creative North Star: "The Screening Room"**

Erica's approved reference supplies the identity: charcoal, a soft screen glow, white actions, and condensed titles printed over scene imagery. The interface gives the image room while keeping recording tasks legible and reachable. This is an existing-reference port, with no generated concept seed or catalog-world provenance.

The implemented native system is recorded from `Dubbing/Theme.swift`, `DiscoverView.swift`, `Library/LibrarySceneDetail.swift`, `DubFlow/SectionPickerView.swift`, `DubFlow/ScriptReviewView.swift`, `DubFlow/DubSessionView.swift`, `MyDubsView.swift`, and `ContentView.swift`. Erica's `erica-frontend/docs/style-guide.md` explains the authority; the main app's code determines the values and behavior here. This document records the system, not a finish-review verdict or a claim that every service is complete.

**Key Characteristics:**

- Scene imagery carries color; interface chrome stays neutral.
- League Gothic belongs to printed artwork and the wordmark; system type carries tasks.
- Native navigation, menus, sheets, and confirmation dialogs frame the workflow.
- Real library and saved-dub data determine counts, frames, and availability.

## Colors

The neutral palette separates the dark room, flat panels, raised controls, and increasingly quiet text. Frontmatter values map to `Palette`; repeated values retain their distinct semantic roles.

### Primary

- **Screen White:** `accent` fills the main action and marks selection; `on-accent` supplies its dark label. `accentText` in Swift aliases this same white.

### Secondary

- **Recording Red:** `record` identifies microphone controls and the live recording badge. The record button remains red at rest as the recognizable recording affordance.
- **Hologram Cyan:** `holo` identifies the coach entry. The retained coach implementation remains its own service-backed surface; the reference's animated hologram is not claimed as ported.
- **System Toggle Green:** `toggle-on` preserves a legible white switch knob.

### Neutral

- **Room Charcoal:** `background` grounds screens and pinned bottom action bars.
- **Screen Glow:** `background-glow` lights the upper center of the room; `hairline` separates list rows.
- **Panel Charcoal:** `surface` supports script, feedback, and compact scene cards; `surface-raised` distinguishes secondary buttons.
- **Track Grey:** `track` supports inactive progress and waveform bars. `segmentInactive` shares it; `divider` shares `hairline`.
- **Reading White / Supporting Grey / Quiet Grey:** `text-primary`, `text-secondary`, and `placeholder` establish text hierarchy. The `streak` alias uses supporting grey.

**The Functional Hue Rule.** Keep selection white; reserve red for recording affordances and cyan for coaching.

Speaker assignment uses neutral swatches in `DubFlowView.swift`, with names and selection marks supplying meaning; those implementation swatches do not establish a new brand palette.

## Typography

**Display Font:** League Gothic, bundled as `LeagueGothic.ttf` with its SIL OFL license and registered as `LeagueGothic-Regular`. Registration fails visibly if the asset is missing; no substituted display face is specified.

**Body Font:** The native system face (SF Pro). `dubFont(_:weight:)` scales the requested base point size through `@ScaledMetric`; `displayFont(_:)` uses the custom face relative to Large Title. Frontmatter sizes are native default-size points, not fixed rendered sizes. Native line metrics are retained.

### Hierarchy

- **Wordmark and poster:** uppercase condensed print, using the frontmatter roles; role cards use the same face at a base size of 34 pt, saved covers at 25 pt.
- **Headline:** bold task and scene-detail headings; Shelf profile uses 30 pt bold.
- **Section / title:** bold section headings and selected-scene captions.
- **Script:** bold current dialogue; surrounding cues and timing stay smaller.
- **Body / button / supporting / label:** readable prose, semibold actions, quiet metadata, and over-image pills. Row titles range from 16–18 pt; counters use monospaced digits.

**The Printed Art Rule.** Use League Gothic for artwork titles, role-card names, and the Dubby wordmark; use system type for interface headings, dialogue, and controls.

## Layout

Scroll content uses page margins from the spacing scale. Discover separates major groups by `section`; scene detail uses 22 pt between narrative groups. Cards commonly use 12–18 pt internal padding. Studio controls use 16 pt side padding and 12 pt vertical padding in a bottom safe-area inset. A solid background under pinned actions maintains separation from scrolling content.

The deck centers a 220 × 330 pt poster on both phone and tablet; wider screens gain surrounding space rather than a new desktop composition. Scene detail leads with edge-to-edge 4:5 imagery; section preview and studio video use 16:9. Role cards use 3:4. Library ranking thumbnails are 52 × 70 pt.

`AdaptiveStack` switches rows to leading-aligned columns at accessibility text sizes. Role grids switch from two flexible columns to one; Shelf uses adaptive columns with a 104 pt minimum, switching to one at accessibility sizes. Content remains scrollable as text grows. There is no project-defined pixel breakpoint scale.

The main app forces dark appearance. Captured evidence includes phone, tablet, and enlarged text; this is not evidence of a separate light appearance or every accessibility text size.

## Elevation & Depth

Flat tonal panels carry task content. The room background uses a radial gradient centered at normalized `(0.5, 0.28)`, from radius 0 to 460 pt. Posters carry the reusable diffuse shadow: black at 55%, radius 24 pt, offset `(0, 14)` pt. Deck depth also scales rear cards down by 13% per step and overlays black at 28% per step. Native navigation and tab materials remain system-owned.

Poster and role titles sit over dark scrims; poster bottoms reach black at 85% and role cards at 90%. Detail imagery fades into the screen background. Do not infer a prohibition on gradients: these gradients are native materials of this world.

Deck focus uses a spring of 0.4 seconds with bounce 0.15. Reduce Motion removes that animation and live drag offset. Scene-preview autoplay is suppressed under Reduce Motion. Native zoom navigation connects unique source IDs to detail. These facts do not imply that every retained service view has been audited for motion.

## Shapes

Use `Radius.poster`, `Radius.card`, and `Radius.control` for the recurring large artwork, panels, and controls. Small library thumbnails use a tighter 10 pt corner; saved covers use 5 pt. Metadata, progress, and waveform bars use capsules. The microphone uses a circle. Role selection has a white 2 pt outline and checkmark; unselected roles have a quiet 1 pt hairline. The record control intentionally has an outer ring, so a blanket ban on borders is inappropriate.

## Components

### Buttons

`PrimaryButtonStyle(cornerRadius:)` is the full-width white main action with dark semibold text, horizontal page padding, and minimum height from the frontmatter. Pressing scales it to 0.98; disabled fill drops to 35% opacity. Existing call sites supply the control radius. `SecondaryButtonStyle` uses a raised neutral fill, 16 pt horizontal padding, minimum height from the frontmatter, and pressed opacity 0.75; it fills width only when its label or caller requests it.

### Cards and metadata

`ScenePoster`, `SceneCard`, and `SavedDubCard` use frames from the real clip or saved export. `VideoThumbnail(url:time:)` requests an exact frame when supplied; idle section and studio stages use relevant midpoint frames. Unavailable thumbnails expose a preview-unavailable symbol rather than substituting invented artwork. `MetaPill` provides compact over-image metadata with 10 pt horizontal padding and 4 pt icon spacing. It is a label, not a 26 pt touch target.

Role cards show the frame near that speaker's first assigned line, editable speaker names, line counts, and speaking time. The frame is temporal context, not guaranteed character recognition. A native disclosure exposes grouping correction, renaming, and line reassignment; menus and dialogue controls have 44 pt minimum heights.

### Navigation and fields

System `TabView` presents Discover, Feed, Create, Inbox, and Shelf with white tint. Discover uses native `.searchable`; renaming uses an alert text field; language and speaker assignment use native pickers and menus. Do not derive custom field chrome from prototype HTML. Scene detail hides the tab bar and retains native back navigation. Section and script screens use inline native titles. Studio uses native toolbar items with a guarded exit when pending or kept takes would be lost.

The Create tab currently opens the creation cover without changing selection. This action-in-tab behavior is recorded as existing drift from native section navigation, not a pattern to extend.

### Recording and truthful states

The microphone is a 78 pt red circle, padded by 5 pt and surrounded by a 2 pt red ring at 40% opacity. Previous and next controls have 44 × 44 pt minimum frames. The current line, waveform, source listening, take playback, retry, and keep actions retain the working recording flow. A pending take must be kept or retried before Finish; Finish remains disabled when unavailable.

The reference's globally silent-app rule is not the main app's behavior: scene-detail preview is muted, while explicit section preview, original listening, cue audio, take review, and saved-result playback retain functional audio. Do not apply the prototype silence rule to these actions.

Loading, failure with retry, empty library, empty Shelf, and unavailable social services are represented honestly. Feed and Inbox use real friend, invitation and shared-video data; invitation and result screens retain native sheets, existing buttons and the screening-room palette. Scores and progress must use available measurements; unavailable pronunciation data does not become sample success. Counts and saved items derive from real data. No prototype rankings, cast recognition, social engagement, or sample feedback are established visual-system content.

## Do's and Don'ts

### Do:

- **Do** reuse `Palette`, `Radius`, `dubFont`, `displayFont`, `.screenBackground()`, and the shared button styles.
- **Do** let real video frames and saved covers carry color and place readable titles on scrims.
- **Do** preserve native navigation, safe-area actions, Dynamic Type reflow, and meaningful accessibility labels.
- **Do** show loading, empty, failed, and unavailable states from actual data.

### Don't:

- **Don't** use League Gothic for interface headings, body text, or buttons.
- **Don't** introduce decorative accent hues into selection or neutral task chrome.
- **Don't** add invented scores, rankings, identities, or service activity to fill the layout.
- **Don't** replace SF Symbols or native controls with emoji, glyph icons, or web-style navigation.
