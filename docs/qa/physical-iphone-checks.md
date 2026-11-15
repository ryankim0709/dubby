# Physical iPhone checks

Owner of the checklist: Revyl QA & Integration. **Every check below is for Ryan to run on a real iPhone.** A simulator or Revyl cloud phone cannot prove any of them, and nothing here has been run or claimed. Record each result next to the commit SHA of the build under test, the iPhone model, and the iOS version, with a screenshot or screen recording and the device log (Console.app or `xcrun devicectl` with a connected Mac).

Build: install a development-signed build of the `Dubbing` scheme on the device (needs an Apple development team and signing, which the QA crew does not have). Use real microphone input, never `-DUBIT_AUDIO_FIXTURE`.

Owners: **Mobile** = Mobile App (DUBB-1), **Engine** = Dubbing Engine (DUBB-5), **Ryan** runs the check. A failure is routed to the owner, with the steps, to fix.

| # | Check | Steps | Expected result | Fix owner |
| --- | --- | --- | --- | --- |
| P-01 | Real permission prompts | Delete the app, reinstall, open it, start recording on the first line; separately start script transcription | The system microphone prompt appears with the app's usage text on first record; the speech-recognition prompt appears with its usage text on first transcription; each appears once | Mobile |
| P-02 | Deny, then recover | Deny the microphone, tap record again, then use the app's open-Settings control, enable Microphone, return | Typed denied state, no take; after returning, recording works with no relaunch | Mobile |
| P-03 | Microphone fidelity | In a quiet room, record each line of the demo scene at normal speaking distance, then play the take back through the speaker and headphones | Speech is intelligible, not clipped or distorted, level is comparable to the original line, no clicks at the start or end | Engine |
| P-04 | Cue, take and video sync | Record a line, then play the exported dub | The take starts with the actor's mouth, within about a quarter second, with no drift across the scene | Engine |
| P-05 | Exported audio content | Export and play the dub full screen with sound | The selected character's original line is gone under the user's take, other characters and music remain, the MP4 plays in Photos and Files | Engine |
| P-06 | Wired headset and AirPods routing | Connect AirPods, then record a line; repeat with wired headphones | Playback of the cue goes to the headset, the take is captured from the headset microphone, level and sync are still acceptable | Engine |
| P-07 | Route change during recording | Start recording, then disconnect the AirPods or unplug the headphones | Recording stops with the interruption state, no take is kept, recording works again afterwards | Mobile |
| P-08 | Phone call | Start recording, call the iPhone from another phone, then decline or hang up | Recording stops, no take is kept, the studio recovers | Mobile |
| P-09 | Siri and alarm | Start recording, invoke Siri, and in a second trial let a timer alarm ring | Same as P-08 for each | Mobile |
| P-10 | Backgrounding | Start recording, press the side button to lock, then unlock; repeat with Control Center and the app switcher | Recording stops, no partial take, studio recovers | Mobile |
| P-11 | On-device speech model | In Settings, check the speech model for the scene language is installed, then run transcription offline (airplane mode) | Transcription works from the on-device model with no network, or the app explains plainly that the model is unavailable | Engine |
| P-12 | Speech model download | Remove the model or use a fresh device and start transcription on Wi-Fi | The app shows model preparation progress and completes, or fails with a retryable message | Engine |
| P-13 | Export under pressure | Start an export with low battery mode on, and again while another app plays audio | Export finishes or fails explicitly, with no hang and no half-saved dub | Mobile |
| P-14 | Share destinations | Share the dub to Messages, AirDrop, Photos and Files | Each destination receives a playable MP4 | Mobile |
| P-15 | Dynamic Type and VoiceOver | Turn on VoiceOver and the largest accessibility text size, run the loop | Every control has a clear name, the record control's name reflects its current action, no truncated controls | Mobile |
| P-16 | Thermal and long session | Dub a full scene twice in a row | No crash, memory warning, or growing latency | Mobile |

Results go in `docs/qa/physical-iphone-results.md` (not yet created), one row per check: result, SHA, device, iOS, evidence link.
