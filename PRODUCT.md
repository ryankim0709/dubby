# Dubby

Dubby is an entertainment-first native iOS app for learning languages by dubbing short scenes. The central journey is to discover a scene, frame a short section, choose a voice, record timed lines, then watch and share the finished dub.

The intended audience is language learners who want to practise through performance and familiar entertainment. Browsing should feel cinematic; recording should make the current line, cue, and next action easy to understand.

## Product boundaries

The working app provides library scenes, transcription and editable voice grouping, timed recording and take review, local export and sharing, account access, measured progress, and character coaching. Feed and Inbox are empty until their services exist. Unavailable pronunciation measurements remain unavailable rather than becoming sample scores.

## Approved design authority

Erica is the product UI/UX designer. Her SwiftUI reference in `erica-frontend/Dubbing/` and `erica-frontend/docs/style-guide.md` define the approved screening-room design for the main app. The user explicitly authorized porting that design into `Dubbing/` while preserving the functioning app services.

This is an existing-reference port; no new visual concept or concept seed was generated. Screen-specific intent is recorded in `.impeccable/surfaces/dubbing-contentview-swift.md`. `DESIGN.md` describes the implemented reusable system.

Implementation and verification conventions remain in `AGENTS.md` and `README.md`.
