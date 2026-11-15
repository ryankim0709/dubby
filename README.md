# DubIt

DubIt is a native iOS app in development for learning languages by dubbing short scenes. The intended experience lets users choose a character, practice timed dialogue, receive pronunciation coaching, and save or share their performance.

This README is the entry point for the project's structure, chosen tools, local development, and planned architecture. Detailed MVP priorities live in the [product rules](.cursor/rules/product.mdc).

The proposed assessment response, scoring rubric, and progress-tracking rules are defined in the [grading contract](docs/grading-contract.md).

## Contents

- [Current state](#current-state)
- [Selected stack](#selected-stack)
- [Project structure](#project-structure)
- [How the app is organized](#how-the-app-is-organized)
- [Run locally](#run-locally)
- [Build and test](#build-and-test)
- [Talking coach](#talking-coach)
- [Planned cloud architecture](#planned-cloud-architecture)
- [Working on the project](#working-on-the-project)

## Current state

The app dubs real scenes end to end on the iPhone, with no sample data. Clips placed in the `Media/` folder are bundled at build time and listed on the Discover tab. From a clip, the dub flow lets you:

1. Frame a scene of up to 30 seconds on a filmstrip timeline.
2. Transcribe it with word timings, split it into lines at sentence ends and pauses, and group lines into characters by voice. You can rename characters and reassign any line.
3. Dub one character in the studio. Each line's original audio plays as a reference, a 1.5-second cue plays before recording, and the video keeps rolling silently while you record so your take lines up with the actor's mouth.
4. Export the scene with your takes mixed in, save it to My Dubs, and share it.

Progress shows a streak and totals computed from saved dubs. DMs shows an empty state until messaging is built.

When the build has a Convex URL, the app opens on a sign-in page: learners sign in or create an account with a username and password, stored in Convex. The shared demo logins are `demo`/`demo` and `demo1`/`demo1`. Setup is in [docs/convex-backend.md](docs/convex-backend.md).

Discover also opens a talking coach. You pick a scene character as your teacher and talk to them in the language you're practising; they answer as a talking video face. The coach's code is in place, but it hasn't run end to end yet because it needs provider keys, a Convex deployment, and an avatar per character. See [Talking coach](#talking-coach).

Known limits:

- **Speaker grouping is approximate.** It clusters speech-band MFCC voice fingerprints and got 6 of 8 lines right on the test scene. Users fix the rest by tapping a line's speaker.
- **Dialogue replacement is filtered, not separated.** Clips don't come with separate dialogue and music tracks, so under the user's lines the original audio crossfades to a copy with the speech band (about 420–3,400 Hz) filtered out. Bass and treble of the music and effects carry on, but music in the speech band is lost there. Curated scenes with prepared dialogue and background tracks would remove this limit.
- **Transcription depends on the device.** On an iPhone, iOS 26 `SpeechTranscriber` is used where Apple reports it supported, then `DictationTranscriber`, then `SFSpeechRecognizer`. Simulator dubbing uses the Convex/OpenAI transcript of the published library video instead, because Apple's speech service can report support but fail to load its model files. Local-only clips still need an iPhone.
- **Backend script timing uses `whisper-1`.** It provides measured word timestamps, which the studio needs. OpenAI schedules this model to shut down on February 26, 2027; a replacement with word timings is needed before then. See [OpenAI's file transcription guide](https://developers.openai.com/api/docs/guides/speech-to-text).
- **The coach hears words, not sounds.** It receives an on-device transcript of what you said, so it can coach wording and grammar but not pronunciation.
- **Not yet built:** pronunciation scoring, character-voice conversion, and drafts.

Impeccable is installed locally in the repository. Capy is the selected coding tool. The Convex backend source for the coach is in `convex/`, but no Convex deployment is configured yet. Revyl and Supermemory are selected but not configured. The coach uses LiveAvatar (by HeyGen) for the avatar video and OpenAI for its replies and voice. Pronunciation-assessment and voice-conversion providers have not been selected.

## Selected stack

- **Swift and SwiftUI:** the iPhone app, targeting iOS 26.0 and later.
- **[Capy](https://docs.capy.ai/quickstart):** our AI coding agent for building features, fixing bugs, and running development checks.
- **[Convex](https://www.convex.dev/):** our cloud backend for database records, file storage, server-side functions, and live updates to the app.
- **[LiveAvatar](https://docs.liveavatar.com/) by HeyGen:** the coach's talking video face, streamed to the app over [LiveKit](https://github.com/livekit/client-sdk-swift). The app adds the LiveKit Swift SDK as a Swift package.
- **[OpenAI](https://developers.openai.com/api/reference/typescript):** writes the coach's replies through the Responses API and voices them with its speech API, called from Convex functions through the official `openai` SDK. It is the only language-model vendor at runtime.
- **[Revyl](https://revyl.com/):** cloud builds, browser-accessible app previews, and automated end-to-end testing of user flows, with screenshots, recordings, and logs for debugging and pull request validation.
- **[Supermemory](https://supermemory.ai/docs/overview/what-is-supermemory):** long-term memory for the tutoring agent, retaining learner goals, preferences, and relevant practice context across sessions.
- **[Impeccable](.agents/skills/impeccable/SKILL.md):** the project-local design skill for UI alignment, native iOS guidance, accessibility, and visual reviews.

Capy helps us build the product, Convex operates its cloud services, Revyl verifies app behavior during development, and Supermemory will supply continuity for personalized tutoring. Supermemory provides memory and retrieval; OpenAI generates the talking coach's responses.

## Project structure

```text
.
├── README.md                         Project overview and developer setup
├── AGENTS.md                         Instructions for coding agents
├── CLAUDE.md                         Imports AGENTS.md for Claude Code
├── .github/pull_request_template.md  Sections for pull request descriptions
├── .gitignore                        Local Xcode state, build output, node_modules, and local clips in Media/
├── docs/
│   └── grading-contract.md           Proposed assessment API and learning-progress semantics
├── package.json, package-lock.json   Convex backend dependencies (convex, OpenAI and Supermemory SDKs, zod, TypeScript, Vitest)
├── convex/
│   ├── http.ts                       Coach HTTP routes: characters, LiveAvatar session tokens, replies
│   ├── coachCharacters.ts            Coach catalog: name, avatar and voice env var names, persona
│   ├── coachReply.ts                 Shared coaching prompt, the OpenAI reply and speech calls
│   ├── liveAvatar.ts                 LiveAvatar session-token request with retries
│   └── tsconfig.json                 Typecheck settings for the Convex runtime
├── Config/
│   └── Dubbing-Info.plist            Adds CoachBackendURL, from the COACH_BACKEND_URL build setting
├── Media/
│   └── README.md                     Where local scene clips go; the clips themselves are git-ignored
├── Dubbing.xcodeproj/
│   ├── project.pbxproj               Targets, build settings, and synchronized folders (Dubbing/, Media/)
│   └── xcshareddata/xcschemes/
│       └── Dubbing.xcscheme          Shared build, run, and test scheme
├── Dubbing/
│   ├── DubbingApp.swift              App entry point
│   ├── ContentView.swift             Tabs, clip and saved-dub loading, and the dub flow launch
│   ├── TabBar.swift                  AppTab and the custom bottom tab bar
│   ├── DiscoverView.swift            Scene cards for the bundled clips; LoadState helpers
│   ├── MessagesView.swift            DMs empty state until messaging exists
│   ├── PracticeProgressView.swift    Streak, week, totals, and recent dubs from saved dubs
│   ├── MyDubsView.swift              Saved dubs, playback, and sharing
│   ├── Theme.swift                   Color and typography tokens, adaptive layouts, shared UI
│   ├── Coach/
│   │   ├── CoachView.swift           Character picker and the call screen
│   │   ├── CoachSession.swift        Coaching loop: listen, transcribe, ask the backend, make the avatar speak
│   │   ├── CoachModels.swift         Characters, turns, activity states, errors, pure helpers
│   │   ├── CoachBackendClient.swift  Convex coach routes and the shared retrying request helper
│   │   ├── LiveAvatarClient.swift    LiveAvatar session start, keep-alive, stop; speak commands and events
│   │   └── AvatarRoom.swift          LiveKit room for the avatar's video and audio and the command channel
│   ├── Library/
│   │   ├── MediaLibrary.swift        Bundled clip catalog and titles
│   │   ├── DubLibrary.swift          Saved dubs on disk (videos plus a JSON index)
│   │   └── PracticeStats.swift       Streak and week calculations
│   ├── DubFlow/
│   │   ├── DubFlowView.swift         Flow navigation and the scene picker
│   │   ├── SectionPickerView.swift   Filmstrip scene framing and language choice
│   │   ├── ScriptReviewView.swift    Transcription progress and the editable script
│   │   ├── DubSessionView.swift      Studio: reference audio, cue, synced recording, interruptions
│   │   ├── DubResultView.swift       Export, trim notices, saving, and sharing
│   │   ├── DubFlowModels.swift       Flow types, timing constants, and errors
│   │   ├── SpeechTranscription.swift Speech engine selection and word-timed transcription
│   │   ├── ScriptBuilder.swift       Line splitting, take placement, and suppression spans
│   │   ├── VoicePrint.swift          MFCC voice fingerprints and speaker clustering
│   │   ├── SpeechBandFilter.swift    Speech-band filter for the original audio under takes
│   │   ├── MediaPipeline.swift       AVFoundation export, audio reading, and the final mix
│   │   └── MediaPlayback.swift       Segment player, recorder, take player, audio session
│   └── Assets.xcassets/              App icon and accent color
├── DubbingTests/
│   ├── DubbingTests.swift            Root view smoke test
│   ├── DubFlowTests.swift            Pipeline, library, stats, and export tests
│   ├── CoachTests.swift              LiveAvatar command and event formats, transcript handling
│   └── Fixtures/two-tone-3s.mp4      Synthetic 3-second video with 80 Hz and 1 kHz tones
├── .cursor/rules/
│   ├── product.mdc                   Product journey and MVP priorities
│   ├── swift.mdc                     Native implementation conventions
│   └── dubbing-pipeline.mdc          Recording, composition, assessment, and service rules
├── .agents/skills/impeccable/        Project-local design skill, its references, and its helper agent definitions
├── .claude/
│   ├── skills/impeccable             Symlink to the Impeccable skill for Claude Code
│   └── agents/                       Impeccable helper agents for Claude Code and Cursor
└── .codex/agents/                    Impeccable helper agents for Codex
```

`.codex/agents/` holds copies of the skill's agent definitions in `.agents/skills/impeccable/agents/`. `.claude/agents/` holds the same instructions with Claude Code frontmatter and script paths under `.claude/skills/impeccable/`. Update both when the skill is upgraded.

The server-side Supermemory client and Revyl configuration will be added when those integrations are implemented. They are not part of the current directory structure.

## How the app is organized

`DubbingApp` creates `ContentView`, which owns the selected `AppTab`, loads the bundled clips (`MediaLibrary`) and saved dubs (`DubLibrary`), and presents `DubFlowView` full screen from Discover or the Create button. Saved dubs reload when the flow closes.

The dub flow is a `NavigationStack` driven by typed `DubFlowStep` values: section, script, studio, and result. Each screen receives the values it needs and owns its transient state. Workflow states are explicit enums, such as the script screen's analysis phase and the studio's current activity.

Side effects live in small clients: `MediaPipeline` and `SpeechTranscription` run off the main actor, and `SegmentPlayer`, `TakeRecorder`, and `TakePlayer` wrap AVFoundation playback and capture. `ScriptBuilder`, `VoicePrint`, `SpeechBandFilter`, and `PracticeStats` are pure and covered by tests. `DubTiming` holds the cue, grace, and padding values shared by recording and export, so the studio's trim warnings match the export.

The coach is a separate full-screen flow opened from Discover. `CoachView` loads the coaches from the backend, and each call is a `CoachSession` that owns the conversation state and its clients. `AvatarRoom` forwards LiveKit's delegate callbacks into an async stream that the session follows on the main actor.

`Theme.swift` is the shared source for the palette, Dynamic Type scaling, accessibility-size layout changes, waveforms, thumbnails, empty states, and common button and header styles. Reuse those components when extending the UI.

## Run locally

Prerequisites:

- macOS and Xcode with an iOS 26 SDK. The project has been verified with Xcode 26.5.
- An iOS 26.0-or-later simulator or device. Transcription works best on a device with Apple's on-device speech model.
- An Apple development team and signing setup when running on a physical iPhone.
- At least one scene clip (`.mp4`, `.mov`, or `.m4v`) in `Media/`. Clips are git-ignored, so each machine supplies its own; release builds must use original or properly licensed scenes.

From the repository root:

```sh
open Dubbing.xcodeproj
```

Choose the `Dubbing` scheme, select an iPhone simulator or your device, and run the app. Any clips in `Media/` are bundled into the build and appear on Discover. With no clips, Discover explains how to add them.

The app runs on an iPhone without Convex credentials, AI service keys, or a Revyl account. Simulator dubbing needs the configured transcription backend; coaching also needs its provider setup. Its one third-party package is the LiveKit Swift SDK, which Xcode fetches on the first build. Microphone and speech recognition permissions are requested the first time they are needed.

## Build and test

List the available simulators:

```sh
xcrun simctl list devices available
```

Build and run tests, adjusting the destination to an installed simulator when needed:

```sh
xcodebuild -project Dubbing.xcodeproj -scheme Dubbing \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/dubbing-derived-data \
  CODE_SIGNING_ALLOWED=NO build test
```

There are no automated CI or QA checks for the hackathon. The commands in this section are available for manual use; pull requests merge once their conflicts are resolved.

Typecheck the Convex backend after `npm install`:

```sh
npm run typecheck
```

Compilation performs Swift typechecking. `DubbingTests` uses Swift Testing and covers the coach's LiveAvatar message formats and line splitting, take placement and trim reporting, scene framing limits, voice grouping, the speech-band filter, streaks, the saved-dub library, and a real export against the synthetic fixture. The export test checks that the 1 kHz tone is filtered out under a take while the 80 Hz tone carries on. There is no separate linter or formatter configuration and no Revyl test suite yet.

Recording, playback, interruptions, audio routes, and on-device transcription need an actual iPhone for manual verification; the Simulator cannot verify microphone quality or transcribe speech on the device.

Simulator dubbing requires `COACH_BACKEND_URL` and `OPENAI_API_KEY` on that Convex deployment. `POST /scenes/transcribe` accepts only a published scene's slug, stored-video SHA-256, and matching locale; it never accepts learner recordings or arbitrary URLs. The backend transcribes the stored video once and caches its word timings by video ID and locale. Concurrent requests share a lease, and replacing the stored video creates a new cache entry. The app clips those full-video timings to the selected section and converts them to section-relative seconds. Published videos must be at most 24 MB and 120 seconds for this path.

Revyl remains available for cloud builds and app previews. Its build configuration is in `.revyl/config.yaml`; no automated Revyl test plans are configured.

## Talking coach

A learner picks a character as their teacher, such as Anakin or Obi-Wan for the Star Wars test clip. One coaching system powers every character. Each character is a LiveAvatar image avatar, an OpenAI voice, and a persona prompt, defined in `convex/coachCharacters.ts`.

One turn of the conversation:

1. The learner taps the mic and speaks. The app records to a temporary file and transcribes it on the iPhone with the dub flow's `SpeechTranscription`, then deletes the file.
2. The app sends the conversation so far to the backend's `POST /coach/reply`. The Convex function asks OpenAI (`gpt-6-luna` through the Responses API, no reasoning, `store: false`; override with `OPENAI_COACH_MODEL`) for a short spoken reply grounded in the learner's stored practice. The system prompt combines the shared coaching rules with the character's persona.
3. With `audio: true` in the request, the reply also carries OpenAI speech as one-second chunks of 24 kHz mono 16-bit PCM (base64). The app forwards each chunk to the LiveAvatar LITE session's WebSocket as an `agent.speak` command, then sends `agent.speak_end`, and the avatar says the reply word for word. The session's `agent.speak_started` and `agent.speak_ended` events drive the button's state, and the learner can tap to interrupt with `agent.interrupt`. If speech generation fails, the reply still returns its text with `audio: null` and an `audioError` code. The exact shape is in the tutoring interface document, section 4.

The learner's microphone is never published to the LiveKit room, and sessions are created in LiveAvatar's LITE mode, where LiveAvatar runs no speech recognition, language model or voice and only renders video from the audio the app sends it. The avatar therefore says only what OpenAI wrote and voiced. Voices are OpenAI's stock voices only; no custom or cloned voice is used. The learner's recordings never go to LiveAvatar or to speech generation.

OpenAI's text-to-speech models (`gpt-4o-mini-tts`, `tts-1`, `tts-1-hd`) shut down on 2027-01-06, and the named replacement `gpt-realtime-2.1-mini` isn't a speech-endpoint model. The speech model stays configurable with `OPENAI_TTS_MODEL` until that migration is decided.

### Keys and sessions

The LiveAvatar and OpenAI keys exist only as Convex environment variables. `POST /coach/session-token` uses the LiveAvatar key to mint a LITE-mode token for one session. The app then starts that session, keeps it alive every 60 seconds, and stops it with that token, the same flow as LiveAvatar's official web SDK. The app never holds a long-lived key.

The coach routes require a signed-in learner except the public coach list, because they spend LiveAvatar credits and OpenAI tokens.

### Setting it up

These steps create accounts and avatars and can cost money, so the project owner does them.

1. Create a Convex project with `npx convex dev`. It logs in and deploys `convex/`.
2. Set the deployment's environment variables in the Convex dashboard or with `npx convex env set`:
   - `LIVEAVATAR_API_KEY` and `OPENAI_API_KEY`; optionally `OPENAI_COACH_MODEL` and `OPENAI_TTS_MODEL`. Tutoring memory also needs `SUPERMEMORY_API_KEY` and `TUTOR_MEMORY_NAMESPACE_SECRET`.
   - `LIVEAVATAR_AVATAR_ID_ANAKIN`, and the matching `…_OBI_WAN` ID. Voices are OpenAI voices set in `convex/coachCharacters.ts`.
   - `LIVEAVATAR_SANDBOX=true` to test for free. Sandbox sessions use LiveAvatar's stock sandbox avatar for every character and end after about a minute.
3. Create one image avatar per character. Each uses one avatar slot on the LiveAvatar plan. Image avatars come from a single clear, front-facing photo, either in the dashboard or with the alpha `POST /v1-alpha/avatars/image` endpoint. Use original artwork you're authorized to use. Don't use frames from the film or a real actor's likeness.
4. Point the app at the deployment by setting the `COACH_BACKEND_URL` build setting to the Convex site URL (`https://<deployment>.convex.site`), either in the Dubbing target or on the `xcodebuild` command line. Until it's set, the coach screen says the backend isn't configured.

### Not verified yet

- No real LiveAvatar session has run with this backend's audio, and the OpenAI and Supermemory calls haven't run with real keys. The app's LITE WebSocket client is still to be built.
- The coach's audio needs an actual iPhone. The app manages the audio session itself, so the recorder and LiveKit playback can share it. Recording during playback, interruptions, Bluetooth routes, and echo still need testing on a device.
- The Convex functions typecheck but haven't been deployed or bundled by Convex.

## Planned cloud architecture

The iPhone will own the interface, audio recording, playback, line timing, audio mixing, MP4 export, and native sharing. Local drafts and recordings should remain available while cloud processing is in progress.

Convex will provide:

- **Database records:** users, scene and character metadata, dialogue timestamps, dubbing projects, accepted takes, assessments, and history.
- **File storage:** scene assets and audio tracks, user recordings, and completed videos. Database records will reference these files.
- **Backend functions:** authorized requests to external AI services, recording assessment results, and updating processing status. Long-lived provider keys stay on the server. The coach's HTTP routes in `convex/http.ts` are the first of these.
- **Live updates:** changes to project status and saved results delivered to the app.

The app will use Convex's [Swift SDK](https://docs.convex.dev/client/swift/overview) for database-backed features. The coach currently calls Convex HTTP actions backed by the TypeScript functions in `convex/`. Provider credentials stay off the iPhone; authenticated ownership checks and the assessment and Supermemory integrations remain to be implemented.

A planned pronunciation-feedback flow is:

1. The iPhone records the current line and retains the original take locally.
2. The app uploads that take and associates it with the user's dubbing project in Convex.
3. A Convex backend function requests an assessment from the selected speech service.
4. Convex saves the assessment, and the app receives the updated result.
5. The user retries or accepts the take. The iPhone composes the accepted takes into the scene and can upload the finished video for cloud history or sharing.

Revyl provides development builds and app previews. Automated QA and pull request checks are disabled for the hackathon.

### Long-term tutoring memory

Supermemory will let the tutoring agent carry useful context between practice sessions: the learner's stated goals, language preferences, recurring difficulties supported by assessments, and prior coaching or practice commitments. The talking coach currently receives only the conversation supplied by the app; long-term memory is not integrated yet.

Convex remains the source of truth for attempts, assessments, accepted takes, and progress calculations under the [grading contract](docs/grading-contract.md). Supermemory stores context derived from that history and from the learner's explicit preferences. Retrieved memories inform coaching; measured scores and improvement claims must come from the underlying assessments and Convex calculations.

The planned tutoring flow is:

1. A validated assessment is saved in Convex, linked to its original attempt and reference line.
2. The backend sends a concise, evidence-backed practice summary to Supermemory, retaining references to the supporting attempts and assessments in Convex. Raw recordings stay in the media storage path.
3. When the learner requests coaching or starts another practice session, the backend retrieves relevant memory for that authenticated learner and combines it with the current line, assessment, and computed progress.
4. The tutoring model produces actionable coaching grounded in that evidence. The backend saves the interaction and updates useful memory for future sessions.

The backend must derive memory isolation from the authenticated user, rather than trusting a client-supplied user identifier. Disclose third-party memory processing before sending learner data, and support correcting or deleting derived memory alongside the corresponding learner data. Track memory-processing failures explicitly so a failed update can be retried without losing the saved assessment. Exact memory payloads and retention rules are still implementation decisions.

## Working on the project

- Use Capy for coding tasks. Give it a focused behavior to implement and the relevant acceptance checks; it should read this README and [AGENTS.md](AGENTS.md), reuse existing logic, and report the diff and verification results. Run Swift build and tests on a Mac with Xcode or through the planned Revyl build setup. Commits, pushes, and pull requests require explicit authorization under the repository rules.
- Read [AGENTS.md](AGENTS.md) before changing code. It links the product, Swift, and media-pipeline instructions.
- Follow the [product rules](.cursor/rules/product.mdc) for the core solo dubbing milestone and the priority of later features.
- Use the project-local [Impeccable skill](.agents/skills/impeccable/SKILL.md) for UI design and review, with its native iOS guidance and the existing shared theme.
- Keep fixture content distinct from real recordings, assessments, and backend results. Sample scores and messages are not evidence of working integrations.
- Use original or properly licensed scenes and authorized voices for release assets.
