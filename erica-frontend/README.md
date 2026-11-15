# Dubby frontend (v0)

A self-contained SwiftUI app with the full Dubby user journey and visual design, built on sample data and synthetic media so it runs without a backend. It lives in its own folder so it doesn't touch the main app in `../Dubbing`; pull screens and components across from here as you integrate.

## Run it

Open `erica-frontend/Dubbing.xcodeproj` in Xcode 26, pick an iPhone simulator, and press ⌘R. From the command line:

```sh
xcodebuild -project erica-frontend/Dubbing.xcodeproj -scheme Dubbing \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/dubby-frontend CODE_SIGNING_ALLOWED=NO build test
```

This project uses the same bundle identifier as the main app (`com.ryankim.Dubbing`), so installing one on a simulator or device replaces the other.

## What's here

- **Discover**: stacked poster deck with language tabs and a ranked Most dubbed list; tapping a poster zooms it into the scene's detail page.
- **Dub flow**: role casting; a line-by-line studio (silent picture playback, count-in, dual waveforms, measured timing score); the hologram coach after each take; a full-screen pronunciation tutor after the last line; wrap with MP4 export, save, and share.
- **Language learning**: line translations in the learner's home language, dual subtitles, and tap-a-word meanings, with settings to switch it and the coach off.
- **Feed, Inbox (co-dub invites), Shelf (profile and DVD shelf)**.

## Docs

- `docs/style-guide.md`: colours, type, radii, components, and motion. Use this when building UI.
- `docs/frontend-handoff.md`: where backend data replaces the sample data and placeholders.

Placeholder content (scene media in `Dubbing/Media`, sample feed and shelf data, and the tutor's sample feedback) is synthetic or clearly labelled as such.
