# Dub-loop smoke flow

Owner: Revyl QA & Integration (crew thread DUBB-17). Status: **specification for the target flow**. It describes what a clean install must do, with the identifiers from [accessibility-ids.md](accessibility-ids.md). Where the baseline app (main @ d5ff617) already differs, the row says so, and a difference is a finding for the owning captain, never a reason to loosen a step.

The same flow is automated three ways, and each step below says which:

| Layer | Where | Runs on |
| --- | --- | --- |
| XCUITest | `DubbingUITests/` | iOS simulator via `xcodebuild test` (Revyl macOS runner through `tools.mobile.build`) |
| Revyl test plan | `.revyl/tests/*.yaml` | Revyl cloud iPhone via `revyl test run` |
| Manual driving | a cloud iPhone driven through the accessibility tree | Revyl cloud iPhone (recorded in the run record) |

Rules: elements are found by accessibility identifier, or by role plus accessible name for system UI. No raw-text matching, no coordinates, no fallback taps. Evidence goes to the captain drive under `renders/DUBB-17/`, never to git.

## Environment and preconditions

- Build: iOS Simulator `.app` of the `Dubbing` scheme, `CODE_SIGNING_ALLOWED=NO`, iOS 26.0 deployment target kept (never lowered). Record the commit SHA, Revyl build id, Xcode version, runtime, and device model with every result.
- Clean state: `-DUBIT_UI_TEST 1` plus a fresh install (or `xcrun simctl privacy <udid> reset all com.ryankim.Dubbing` and, for XCUITest, `resetAuthorizationStatus(for: .microphone)`). `XCUIProtectedResource` has no speech-recognition case, so the speech permission resets only by fresh install or `simctl privacy`; the helper in `scripts/qa/e2e/` does this before the UI tests.
- Demo scene: the Engine demo scene must be listed on Discover of a fresh build (`-DUBIT_DEMO_SCENE demo` orders it first). The baseline lists nothing on a clean checkout because `Media/*` is git-ignored.
- Microphone: a simulator or cloud phone has no usable microphone, so recording uses the synthetic fixture (`-DUBIT_AUDIO_FIXTURE`), and the app shows `fixtureInputBadge`. That proves the record, keep and export plumbing. It proves nothing about microphone fidelity or speech scoring (see [physical-iphone-checks.md](physical-iphone-checks.md)).
- Network: none required. Coach, sign-in, and cloud assessment are skipped (S-90).

Column "Sim" = can a simulator exercise it: **Yes**, **Partly** (the app-side state yes, the real-world cause no), **No** (physical iPhone only).

## Happy path (grant permissions)

| Step | Action | Element (identifier, or role + name) | Expected result | Evidence | Sim |
| --- | --- | --- | --- | --- | --- |
| S-01 | Launch a clean install | `discoverScreen` | Discover appears; no crash; no permission prompt yet | screenshot `discover-clean`, app log | Yes |
| S-02 | Open My Dubs on a clean install | `tab-myDubs`, `myDubsEmpty` | Empty state, `myDubsCount` absent or 0; then return with `tab-discover` | screenshot `my-dubs-empty` | Yes |
| S-03 | Find the demo scene | `sceneCard-<sceneID>` | Present with the scene's title and a thumbnail; `discoverEmpty` absent | screenshot | Yes |
| S-04 | Start the scene | `dubScene-<sceneID>` | Flow opens to its first screen | screenshot | Yes |
| S-05 | Set up the scene (baseline only: frame scene, then transcribe) | `sectionScreen`, `transcribeScene`, `transcribeProgress` | Progress reaches `ready`. Baseline asks for speech-recognition permission here (S-32) and the simulator has no on-device speech model, so this step may fail on a simulator; the curated flow should skip it | screenshot per progress value | Partly |
| S-06 | Review the script | `scriptScreen`, `scriptLine-<lineID>` | Every line of the scene is listed with its character; line count > 0 | screenshot `script-review` | Yes |
| S-07 | Choose a character | `characterCard-<characterID>` | Card has the selected trait; `startDubbing` enabled only when that character has lines | screenshot | Yes |
| S-08 | Enter the studio | `startDubbing`, `studioScreen` | `studioStatus` = `idle`; `studioProgress` = `0 of N`; `currentLine` is the first line of the chosen character | screenshot `studio-opened` | Yes |
| S-09 | Listen to the original | `listenToOriginal` | `studioStatus` goes `playingOriginal` then `idle`; `recordLine` is disabled while playing | screenshot, log | Yes (video; audio output unverifiable) |
| S-10 | First record: grant microphone | `recordLine`, system alert, button "Allow" | Prompt appears once; after Allow, `recordingIndicator` appears and `studioStatus` = `recording`; with the fixture `fixtureInputBadge` is visible | screenshots `mic-prompt` and `recording` | Yes (prompt and plumbing); No (real microphone) |
| S-11 | Recording ends | `recordingIndicator` disappears | `studioStatus` returns to `idle`; a take exists (`playTake` appears); a take over the line window shows `takeTrimNotice` | screenshot | Yes |
| S-12 | Play the take back | `playTake` | `studioStatus` = `playingTake` then `idle` | log | Yes (state); No (audio quality) |
| S-13 | Keep the take | `keepTake` | `lineKept-<lineID>` appears; `studioProgress` increments by one | screenshot `line-1-kept` | Yes |
| S-14 | Retry a line and keep the retry | `retryTake`, `recordLine`, `keepTake` | The kept take is replaced only after the new one is kept; `studioProgress` does not change | screenshot | Yes |
| S-15 | Move through every line | `studioNext`, `studioPrevious`, repeat S-09..S-13 | `currentLine` changes; `studioProgress` reaches `N of N`; `finishDub` enabled | screenshot per line | Yes |
| S-16 | Export | `finishDub`, `exportScreen`, `exportStatus` | Status moves `filteringDialogue` -> `mixing` -> `saving` -> `finished`; no result is shown before `finished` | screenshot per status, log | Yes |
| S-17 | Preview | `resultPlayer` | `accessibilityValue` = `ready`; playback starts; trim notice `dubTrimNotice` only if a take was cut | screenshot, recording | Yes (plays); No (audio sync by ear) |
| S-18 | Save | `saveDub` (if explicit) and `savedStatus` | `savedStatus` = `saved`; baseline saves automatically, so the explicit step may not exist | screenshot | Yes |
| S-19 | Share from the result | `shareDub`, system element `ActivityListView`, button "Close" | Share sheet opens with the MP4; Close dismisses it with no destination chosen | screenshot `share-sheet` | Yes (sheet opens); No (destinations) |
| S-20 | Leave the flow | `doneDub` | Back on Discover | screenshot | Yes |
| S-21 | Reopen My Dubs | `tab-myDubs`, `myDubsScreen`, `myDubsCount`, `savedDub-<dubID>` | Count = 1, the card shows `N of N` lines | screenshot `my-dubs-one` | Yes |
| S-22 | Persistence | terminate and relaunch without `-DUBIT_UI_TEST`, repeat S-21 | The dub is still listed | screenshot | Yes |
| S-23 | Play and share a saved dub | `savedDub-<dubID>`, `savedDubPlayer`, `savedDubShare`, "Close", `savedDubDone` | Player opens, share sheet opens and closes, sheet closes | screenshot | Yes |

## Permission paths

| Step | Action | Element | Expected result | Evidence | Sim |
| --- | --- | --- | --- | --- | --- |
| S-30 | Deny the microphone | `recordLine`, alert button "Don't Allow" | No recording starts, no take, `microphonePermissionBanner` value `denied`, `studioError` value `microphoneDenied` (typed state, not a generic failure) | screenshot `microphone-denied` | Yes |
| S-31 | Recover through Settings | `openSettings`, Settings switch "Microphone", return, `permissionRetry` | Settings opens on the app's page; after the switch is on and the app returns, the banner clears and recording works | screenshots, log | Yes |
| S-32 | Deny speech recognition (baseline transcription step) | `transcribeScene`, alert button "Don't Allow" | `speechPermissionNotice` value `denied`; no script is produced; a path back to the permission exists | screenshot | Yes |
| S-33 | Restricted permission (parental/MDM restriction) | n/a | Banner value `restricted`, with no Settings recovery offered | n/a | No (needs a restricted device) |
| S-34 | Prompt reappearance | Fresh install | The prompt appears once per install; deny is remembered across relaunch | log | Yes |

## Failure, cancellation and interruption

| Step | Action | Element | Expected result | Evidence | Sim |
| --- | --- | --- | --- | --- | --- |
| S-40 | Cancel a recording in progress | `recordLine` or `cancelRecording` while `recordingIndicator` shows | Recording stops, no partial take is kept | screenshot | Yes |
| S-41 | Cancel a retry | `retryTake`, `cancelRecording` | The take kept before the retry is still kept, still plays, `studioProgress` unchanged (swift.mdc rule) | screenshots before and after | Yes |
| S-42 | Background during recording | home, then return | `studioStatus` = `interrupted`, `studioError` value `recordingInterrupted`, no take kept, and `recordLine` works again | screenshot, log | Yes (backgrounding); No (real calls) |
| S-43 | Foreground during playback | home, then return while `playingOriginal` | Playback stops cleanly, `studioStatus` = `idle` | screenshot | Yes |
| S-44 | Cancel an export | `cancelExport` | `exportStatus` = `cancelled`; partial output is deleted; `retryExport` and `exportBack` appear; My Dubs is still empty | screenshots, My Dubs screenshot | Yes (needs a slow export, see `-DUBIT_EXPORT_STEP_DELAY_MS`) |
| S-45 | Background during export | home, then return | Export ends in `finished`, `failed` with `exportError` and `retryExport`, or `cancelled`, never stuck on a status | screenshot, log | Yes |
| S-46 | Retry a failed export | `retryExport` | A failure produces no saved dub; the retry produces exactly one | screenshots | Partly (needs an injectable failure; none exists) |
| S-47 | Audio route change, call, Siri | n/a | Recording stops with the interruption state | n/a | No (see physical checklist) |
| S-48 | Low disk, killed during export | n/a | No half-written dub is listed after relaunch | n/a | Partly (kill during export is testable; low disk is not) |

## Skipped steps and blockers

- **S-90 Coach, sign-in, cloud assessment.** Blocker, owner Convex Backend (DUBB-4): no development deployment, sandbox credentials, or test identity exists (confirmed by DUBB-4 on 2026-11-15; the auth provider is not chosen). These steps are not in the smoke tests. Re-add them when DUBB-4 announces a deployment URL and a test identity.
- **Pronunciation score and coaching.** The fixture is synthetic, so any score on a fixture take would be meaningless. The smoke flow never reads or asserts a score; the app must not show one for a fixture take.
- **Audio content.** The flow asserts that the exported MP4 plays and has the expected duration. It does not prove the intended audio is audible; that is a physical-iPhone check.

## Run record (fill per run)

Every run records: commit SHA of each branch combined, Revyl build id, Xcode version, simulator runtime or device model with iOS version, the launch arguments, pass or fail per step id, and for each failure the reproduction steps and evidence paths. Test names map to steps:

| Test | Steps |
| --- | --- |
| `SmokeFlowTests.testDubLoopFromCleanInstallToShare` | S-01 to S-04, S-06 to S-23 (S-05 only where it exists) |
| `PermissionTests.testMicrophoneDeniedShowsRecoveryAndRecordsAfterGrantInSettings` | S-30, S-31 |
| `PermissionTests.testSpeechRecognitionDeniedShowsRecoverableState` | S-32 |
| `InterruptionTests.testCancelMidRecordingKeepsThePreviouslyKeptTake` | S-41 |
| `InterruptionTests.testBackgroundingDuringRecordingDiscardsTheInterruptedTake` | S-42 |
| `InterruptionTests.testExportCancelLeavesNoSavedDub` | S-44 |
| `InterruptionTests.testBackgroundingDuringExportEndsInAnExplicitState` | S-45 |
| Revyl `.revyl/tests/dub-loop.yaml`, `microphone-permission.yaml`, `cancel-and-interruptions.yaml` | the same steps, driven through the accessibility tree |

## Baseline gaps (main @ d5ff617), for the owning captain

These come from reading the source, not from a run, and are leads until a run confirms them:

1. Discover is empty on a clean checkout (clips are git-ignored). Owner: Engine (demo scene).
2. No `keepTake` or `retryTake`: a finished recording becomes the line's take immediately (`DubSessionView.record()`). Owner: Mobile.
3. Stopping a recording early stores the partial take, so stopping a retry overwrites the previously accepted take, which swift.mdc forbids. Owner: Mobile (view) with Engine (`TakeRecorder`).
4. No export cancel, no explicit save step (`DubResultView` saves automatically), no `exportStatus` or `savedStatus` state carriers. Owner: Mobile.
5. A denied microphone surfaces as `DubFlowError.microphoneDenied` text with no Settings path. Owner: Mobile.
6. Most controls lack identifiers; `dubScene` repeats per card. Owner: Mobile.
