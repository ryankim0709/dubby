# Accessibility identifier contract

Owner of this document: Revyl QA & Integration (crew thread DUBB-17). Owner of the implementation: Mobile App (DUBB-1) for views and launch handling, Dubbing Engine & Demo Assets (DUBB-5) for the audio-input fixture and the demo scene. Status: **proposed**; nothing here is implemented until the owners say so. The baseline (main @ 33a7a9b) already carries the identifiers marked **existing**; every other row is a request.

The smoke flow ([smoke-flow.md](smoke-flow.md)), the XCUITests in `DubbingUITests/`, and the Revyl tests in `.revyl/tests/` find elements only by these identifiers, or by role plus accessible name where a system control has no identifier. Raw visible text and coordinates are never used.

## Rules for the implementer

1. Identifiers are camelCase and never localized. Per-item identifiers append `-<stable id>` (the existing `coach-<id>` pattern), where the id is the model id (scene id, character/speaker id, line id, dub UUID) and never a list position.
2. Put `.accessibilityIdentifier` on the control itself (the Button, ShareLink, Stepper), not on a wrapper stack, so the element type is right.
3. Do not reuse one identifier for two elements visible at the same time. The baseline's `dubScene` is repeated on every scene card, so it becomes `dubScene-<sceneID>`.
4. Identifiers on state carriers expose the state through `accessibilityValue` (a short enum raw value listed below), so a test can assert a state without reading prose. State carriers may be accessibility-only elements (no visual) but must be real UI state, never a mock.
5. Accessible **labels** stay user-facing and localizable. A control whose action changes keeps one identifier and changes its label (the baseline's `recordLine`: "Record this line" / "Stop recording").
6. Synthetic input is always labeled: when the audio-input fixture is active, `fixtureInputBadge` exists, and no score or coaching result may be derived from it (see Engine rows).

## Launch contract

iOS launch arguments of the form `-KEY value` populate `UserDefaults.standard`'s argument domain; XCUITest (`launchArguments`) and Revyl (launch configuration, iOS argument set) both deliver them unchanged. Only these are read, and only in DEBUG builds or builds with `DUBIT_QA` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (Mobile App decides the mechanism; a Release build must ignore them).

| Argument | Owner | Behavior |
| --- | --- | --- |
| `-DUBIT_UI_TEST 1` | Mobile | Clean state at process start: delete saved dubs and the dub working directories, clear the app's UserDefaults, reset in-memory flow state; disable UIKit animations. Never touches system permission state (tests use `resetAuthorizationStatus`). |
| `-DUBIT_DEMO_SCENE <sceneID>` | Engine + Mobile | The demo scene is listed first on Discover and in the Create picker. When the argument is absent the demo scene is still bundled and listed, so a Revyl run on a plain install can find it. |
| `-DUBIT_AUDIO_FIXTURE <resourceName>` | Engine | DEBUG/QA only. Recording reads the named bundled audio file instead of the microphone, at real time, producing a normal take. Shows `fixtureInputBadge`. The microphone permission prompt still appears and is still honored (denied means the recording fails the same way as with a real microphone). |
| `-DUBIT_EXPORT_STEP_DELAY_MS <n>` | Mobile or Engine | Optional DEBUG/QA delay between export phases so cancel and background/foreground can be exercised on a short synthetic scene. It slows real work; it never skips or fakes it. |

## Identifiers

Type is the XCUIElement type. "Exists today" is the baseline state.

### Global

| Identifier | Type | Value / notes | Exists today |
| --- | --- | --- | --- |
| `tab-discover`, `tab-messages`, `tab-progress`, `tab-myDubs` | button | Selected state through the `isSelected` trait | no (buttons have labels only) |
| `createDub` | button | Create tab button | **existing** |

### Discover

| Identifier | Type | Notes |
| --- | --- | --- |
| `discoverScreen` | other | Root of Discover |
| `sceneCard-<sceneID>` | other | Card container |
| `dubScene-<sceneID>` | button | Replaces the repeated `dubScene` |
| `discoverEmpty` | other | Empty-library state |
| `discoverLoadFailed` | other | Library failed to load |
| `talkToCoach` | button | **existing**; coach is out of the smoke flow |

### Scene setup, character choice, script review

The baseline has Frame the scene → Transcribe → Script review with speaker cards. The curated-scene flow may drop or merge screens; whichever screens ship need these identifiers.

| Identifier | Type | Value / notes | Exists today |
| --- | --- | --- | --- |
| `sectionScreen` | other | Frame-the-scene screen (baseline only) | no |
| `transcribeScene` | button | Baseline transcription start | **existing** |
| `transcribeProgress` | other | `accessibilityValue`: `extractingAudio`, `preparingModel`, `transcribing`, `groupingVoices`, `ready`, `failed` | no |
| `transcribeRetry` | button | Retry after failure | no |
| `scriptScreen` | other | Script review root | no |
| `scriptLine-<lineID>` | other | One line row; value: `<characterID>` | no |
| `characterCard-<characterID>` | button | `isSelected` trait when chosen | no |
| `startDubbing` | button | Begins the studio for the chosen character | **existing** |
| `speechPermissionNotice` | other | Speech-recognition denied or restricted: value `denied` or `restricted` | no |

### Studio

| Identifier | Type | Value / notes | Exists today |
| --- | --- | --- | --- |
| `studioScreen` | other | Studio root | no |
| `studioStatus` | other | Value: `idle`, `playingOriginal`, `recording`, `playingTake`, `interrupted` | no |
| `studioProgress` | other | Value: `<kept> of <total>` (digits only, e.g. `2 of 4`) | no |
| `currentLine` | other | Value: `<lineID>` of the line on screen | no |
| `listenToOriginal` | button | Label toggles Listen/Stop | **existing** |
| `recordLine` | button | Label toggles "Record this line"/"Stop recording" | **existing** |
| `recordingIndicator` | other | Exists only while recording | no |
| `cancelRecording` | button | Discards the in-flight take and keeps any previously kept take (swift.mdc: cancelling a retry must not destroy a kept take) | no |
| `playTake` | button | Plays the current take | **existing** |
| `keepTake` | button | Keeps the just-recorded take for this line | no |
| `retryTake` | button | Records again; the kept take stays until the new one is kept | no |
| `lineKept-<lineID>` | other | Exists while the line has a kept take | no |
| `studioPrevious`, `studioNext` | button | Line navigation | no |
| `finishDub` | button | Enabled when at least one take is kept | **existing** |
| `takeTrimNotice` | other | Take overruns the line window | **existing** |
| `studioError` | other | Typed error text; value: error case (`microphoneDenied`, `recordingInterrupted`, `recordingFailed`, ...) | no (text only) |
| `microphonePermissionBanner` | other | Shown after denial; value `denied` or `restricted` | no |
| `openSettings` | button | Deep link to the app's Settings page; only on a denied banner | no |
| `fixtureInputBadge` | other | Present only when `-DUBIT_AUDIO_FIXTURE` is active. Label states the input is synthetic | no |

### Export, preview, save

| Identifier | Type | Value / notes | Exists today |
| --- | --- | --- | --- |
| `exportScreen` | other | Result/export root | no |
| `exportStatus` | other | Value: `filteringDialogue`, `mixing`, `saving`, `finished`, `cancelled`, `failed` | no |
| `cancelExport` | button | Cancels the running export and deletes partial output; no dub is saved | no |
| `retryExport` | button | After `failed` or `cancelled` | no (baseline "Try again" has a label only) |
| `exportError` | other | Failure text; value: error case | no |
| `exportBack` | button | Leaves a cancelled or failed export without saving (baseline: "Back" label only) | no |
| `resultPlayer` | other | The preview AVPlayer surface; `accessibilityValue`: `ready` once the item is playable | no (label only: "Your dubbed scene") |
| `saveDub` | button | Not used: saving is automatic and `savedStatus` carries it (confirmed on the native-flow branch) | n/a |
| `savedStatus` | other | Value: `saving`, `saved`, `failed` | no |
| `dubTrimNotice` | other | Trim notice on the result | **existing** |
| `shareDub` | button | ShareLink on the result | **existing** |
| `doneDub` | button | Leaves the flow | no (label "Done") |

### My Dubs

| Identifier | Type | Value / notes | Exists today |
| --- | --- | --- | --- |
| `myDubsScreen` | other | Root | no |
| `myDubsEmpty` | other | Empty state | no |
| `myDubsCount` | other | Value: integer | no |
| `savedDub-<dubID>` | button | Card; value: `<linesDubbed> of <totalLines>` | no |
| `savedDubPlayer` | other | Playback sheet root | no |
| `savedDubShare` | button | ShareLink in the playback sheet | no (label "Share dub") |
| `savedDubDone` | button | Closes the sheet | no (label "Done") |

### Implemented on mobile/native-flow (637f17c, read from source)

State carriers and containers are in place for `discoverScreen`, `sceneCard-<sceneID>`, `dubScene-<sceneID>`, `scriptScreen`, `characterCard-<id>`, `studioScreen` with `studioStatus`, `studioProgress`, `currentLine`, `lineKept-<id>`, the studio controls (`keepTake`, `retryTake`, `cancelRecording`, `recordingIndicator`, `studioBack`), `microphonePermissionBanner` (value `denied`) with `permissionRetry` (button "Check again", which re-reads access and starts the recording), `studioError` with `studioRetry`, `speechPermissionNotice` and `transcribeError` with `transcribeRetry`, `exportScreen` with `exportStatus` and `savedStatus`, `resultPlayer`, `cancelExport`, `retryExport`, `exportBack`, `doneDub`, `tab-*`, `myDubsScreen`, `myDubsCount`, `savedDub-<dubID>`, `savedDubPlayer`, `savedDubShare`, `savedDubDone`, `confirmDeleteDub`, plus `takeFeedback`, `takeSummary`, `measuredTakes`, `retryLoad`. Saving is automatic (no `saveDub`): the tests read `savedStatus`. Export has an extra phase, `measuring`, between `mixing` and `saving`. Not yet verified by a build: whether each element has the type and value the tests expect.

Still missing on that branch as of 637f17c: `fixtureInputBadge` (Engine), `feedbackBasis` and `pronunciationScore` (Mobile, in progress on #4), and the demo scene (Engine).

### Coach runtime provider (QA/DEBUG only; blocked until a development deployment exists)

Shown only with `-DUBIT_UI_TEST 1`. They expose facts the app already holds, never a secret.

| Identifier | Type | Value / notes |
| --- | --- | --- |
| `coachReplyText` | other | The latest coach reply text exactly as received from the backend |
| `coachReplyProvenance` | other | Value `<provider>/<model>` from the reply envelope, for example `openai/<model id>`; absent when the reply had no model |
| `coachAvatarSpeech` | other | Value: the exact string last sent to LiveAvatar as `avatar.speak_text` |
| `coachError` | other | Value: backend error code (`not_configured`, `provider_failed`, `provider_timeout`, `unauthenticated`); no `coachReplyText` exists while it shows |
| `coachRetry` | button | Re-sends the same turn after a failure |
| `feedbackBasis` | other | Value `acoustic`, `script_agreement` or `none` for the shown feedback |
| `pronunciationScore` | other | Must exist only when `feedbackBasis` is `acoustic` and the provenance is acoustic; never for transcript agreement or a model opinion |
| launch argument `-DUBIT_QA_COACH_FAULT <missing_key|provider_error|provider_timeout>` | | Makes the QA/DEBUG client add header `X-QA-Fault` to coach requests; the backend honors it only where `QA_FAULTS_ENABLED` is set on a non-production deployment |

### System UI (no app identifiers; role plus accessible name)

| Surface | Query | Notes |
| --- | --- | --- |
| Microphone alert | SpringBoard alert; buttons "Allow", "Don't Allow" | iOS 26 wording to be confirmed on the first run |
| Speech recognition alert | SpringBoard alert; buttons "OK", "Don't Allow" | Same |
| Share sheet | element `ActivityListView` (system identifier); close button "Close" | Do not tap a destination |
| Settings app | bundle id `com.apple.Preferences`; "Microphone" switch for DubIt | Used only to flip the permission back |
