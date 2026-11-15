# Frontend hand-off (erica branch)

The v0 frontend runs on its own with sample data and synthetic media. Each item below is the one place where backend data replaces it.

The app is **silent by design**: every video plays muted, including the studio, and the hologram coach writes its tip instead of speaking. Recording still captures the mic, and the exported MP4 keeps full audio for sharing.

## Where the backend plugs in

| What | Today | Replace in |
|---|---|---|
| Scene catalog | `SampleData.scenes` | `AppModel.scenes` |
| Scene media | Bundled synthetic files in `Dubbing/Media/` | `SceneMediaFiles` + `MediaLibrary.url(for:)` (switch to downloaded file URLs) |
| Pronunciation and fluency scores | Not measured; only timing is scored on device | `StudioEngine.finishRecording()` → add to `LineResult` |
| Coach lines | `CoachScript.message` from measured timing | `HologramCoachPanel.message` |
| Coach visual | Silhouette, or a `coach-<characterID>` image in Assets (a silent talking clip would also fit) | `HologramFigure.silhouette` |
| Feed, shelf, invites, chats | `SampleData.feed / shelf / invites / conversations` | `AppModel` |
| Partner's takes in a co-dub | Original stem plays for the partner's lines | Pass their `Take`s to `SceneComposer.composition(...)` and drop their character from `voicing` |
| Invite links | `dubby://codub/<sceneID>?role=<characterID>` | `WrapView.inviteURL(for:)` |
| Upload from album | Picker only; shows "service not connected" | `CreateSheet` |

## Media contract per scene

Each curated scene needs **separate audio**, not one mixed soundtrack:

- `<scene>-video.mp4`: picture (audio track ignored)
- `<scene>-bed.m4a`: music and effects, no dialogue
- `<scene>-<characterID>.m4a`: one isolated dialogue stem per character, full scene length
- Line timestamps in seconds from the start of the clip, `0 <= start < end <= duration`

The studio removes only the dubbed character's stem, so music and the other actors stay in the mix. `Dubbing/Media/` holds synthetic stand-ins with matching names; drop real files in with the same names to swap them.

## Not yet verified

- No Xcode was available when this was written. The app typechecks for Mac Catalyst under Swift 6, but it has not been built for iOS, run in the simulator, or tested on a device.
- Microphone capture, speaker bleed while recording without headphones, and export/share need checking on a real iPhone.
