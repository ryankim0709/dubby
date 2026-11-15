---
version: 1
slug: "dubbing-contentview-swift"
primary_target: "Dubbing/ContentView.swift"
related_targets: ["Dubbing/DiscoverView.swift","Dubbing/Theme.swift","Dubbing/MyDubsView.swift","Dubbing/DubFlow/DubSessionView.swift"]
---

## Main app design port

Mode: Operate. The artifact is the main native iOS target in `Dubbing/`, based on latest main. Erica's implementation and `erica-frontend/docs/style-guide.md` are the approved visual reference.

## Direction contract

THESIS: Bring Erica's screening-room design into the working main app. Scene imagery leads browsing; a clear current line and recording action lead the studio.

OWN-WORLD: Neutral charcoal and a soft grey screen glow; white actions and selection; League Gothic on poster art and the Dubby wordmark; system type for interface text. Red identifies recording, cyan identifies coaching.

STORY: Browse the real library, open a scene, frame it, choose a role, dub timed lines, then watch and share the saved result. Account and measured progress remain reachable from Shelf.

FIRST VIEWPORT: A compact Dubby wordmark and account action above a fanned 2:3 poster deck, followed by the actual library list. Native tabs follow Erica's Discover, Feed, Create, Inbox and Shelf order. Empty social surfaces state availability honestly.

FORM: Approved existing reference: `erica-frontend/docs/style-guide.md` and Erica’s SwiftUI implementation. No concept seed was rolled; this is an authorized port of an existing design, not a newly generated direction. User: "Erica is our product uiux person so can you port over her design?" and "Do this work off latest main". Reuse her code-led reference, not a replacement concept. Keep the existing media, transcription, account and assessment clients; retain working original-audio and take playback.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance.
