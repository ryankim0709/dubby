# Engine interface (curated scenes, takes, preview, export)

Owner: Dubbing Engine & Demo Assets. Consumers: Mobile's views, Tutoring (line ids and locale), QA (fixture input, states).
Every type below is non-view Swift in the Dubbing target. Existing view-facing signatures are unchanged; these are added alongside.

## Curated scene catalog

Curated scenes live in `Dubbing/DemoScenes/<sceneId>/` and follow Scene Manifest v1. They are separate from the raw clips in `Media/`.

```swift
nonisolated enum CuratedSceneLoader {
    /// Every valid scene in the bundle, plus the ones that failed validation (never listed).
    @concurrent static func loadCatalog(in bundle: Bundle) async -> CuratedSceneCatalog
    @concurrent static func loadScene(manifestURL: URL) async throws -> CuratedScene   // throws SceneValidationError
    /// Exactly the files valid manifests reference (video, poster, background, dialogue).
    static func referencedFiles(manifestURLs: [URL]) -> Set<URL>
    static func manifestURLs(in bundle: Bundle) -> [URL]
}
nonisolated struct CuratedSceneCatalog: Sendable {
    let scenes: [CuratedScene]                     // sorted by title
    let failures: [CuratedSceneLoadFailure]        // manifestFile + SceneValidationError
    func scene(withID id: CuratedScene.ID) -> CuratedScene?
}
nonisolated struct CuratedScene: Hashable, Sendable, Identifiable {
    let id: String            // manifest sceneId, what -DUBBY_DEMO_SCENE names
    let title, synopsis: String
    let locale: String        // BCP-47, e.g. "en-US"
    let durationSeconds: Double
    let videoURL, posterURL, backgroundURL: URL
    let characters: [SceneCharacter]
    let lines: [SceneLine]    // sorted by start
    let attribution: SceneAttribution   // work, creator, license, licenseURL, sourceURL, text (show it)
    func character(withID:) -> SceneCharacter?
    func lines(spokenBy characterID: SceneCharacter.ID) -> [SceneLine]
}
nonisolated struct SceneCharacter: Hashable, Sendable, Identifiable { let id, displayName, description: String; let dialogueURL: URL }
nonisolated struct SceneLine: Hashable, Sendable, Identifiable {
    let id: String            // manifest lines[].id: the backend's line key
    let characterID: String
    let start, end: Double    // seconds from the scene start
    let text: String
    let referenceVersion: Int
    let locale: String        // the scene's BCP-47 locale on every line
    let words: [SceneWord]    // empty when the manifest has no word timings
}
nonisolated enum SceneValidationError: LocalizedError, Equatable, Sendable {
    case unreadableManifest(file:reason:), unsupportedSchemaVersion(Int), invalidSceneID(String), invalidIdentifier(String),
         duplicateIdentifier(String), unsupportedLocale(String), invalidSceneDuration(Double),
         invalidLineTiming(lineID:start:end:), linesNotSortedByStart(lineID:), unknownCharacter(lineID:characterID:),
         overlappingLines(characterID:first:second:), invalidWordTiming(lineID:word:), tooFewCharacters(Int),
         noCharacterWithThreeLines, fileNameNotScoped(file:sceneID:), missingFile(String), checksumMismatch(file:),
         unsupportedMedia(file:reason:), durationMismatch(file:expected:actual:), sceneTooLarge(bytes:), characterNotInScene(String)
}
```

Supported locales are `SpokenLanguage.all`.

`MediaLibrary.loadClips(in:)` (unchanged signature) leaves out exactly the files a valid manifest references, so a scene's video never appears twice as a raw clip. A personal clip in `Media/` that merely shares a scene's name prefix still appears, and a manifest that fails validation claims no files.

## Studio setup from a curated scene

No transcription, voice grouping or section framing: the manifest is the script.

```swift
nonisolated enum CuratedSceneStudio {
    @concurrent static func makeSetup(scene: CuratedScene, characterID: SceneCharacter.ID, barCount: Int, workingDirectory: URL) async throws -> DubSetup
    static func newWorkingDirectory() -> URL
}
nonisolated struct DubSetup {          // existing fields unchanged
    let curated: CuratedSceneSelection? // nil for raw clips
    var takeBoundary: TakeBoundary
    func timing(for line: ScriptLine) -> LineTiming
}
nonisolated struct CuratedSceneSelection: Hashable, Sendable {
    let scene: CuratedScene; let characterID: String; let speakerID: Int
    func sceneLine(for line: ScriptLine) -> SceneLine?
}
nonisolated struct ScriptLine {        // existing fields unchanged; id stays a local index
    let reference: LineReference?      // set for curated lines
}
nonisolated struct LineReference: Hashable, Sendable { let lineID: String; let characterID: String; let locale: String; let referenceVersion: Int }
```

For a curated setup, `ScriptLine.id` is the line's position in the manifest and `speakerID` is the character's position, so existing views work unchanged. Use `line.reference?.lineID` and `line.reference?.locale` for `CoachPracticeContext(lineID:locale:)` and the backend.

## Explicit timing

```swift
nonisolated struct DubTimingRules { cueLength 1.5, lineGrace 0.75, suppressionPadding 0.12, noticeableTrim 0.15, rampLength 0.08; static let standard }
nonisolated enum TakeBoundary { case nextLineOfAnyone /* raw clips */; case nextLineOfSameCharacter /* curated */ }
nonisolated enum TakeLimit { case grace; case nextLine(Int); case sceneEnd }
nonisolated struct LineTiming {
    let lineID: Int; let cueStart: Double; let line: TimeSpan; let graceEnd: Double
    let placementLimit: Double; let limit: TakeLimit; let recordingWindow: TimeSpan
    var allowedTakeDuration: Double
}
nonisolated struct TakeDecision {
    let lineID: Int; let url: URL; let start: Double          // always the line start: the timeline never shifts
    let recordedSeconds, placedSeconds: Double
    let trimmedBy: TakeLimit?                                  // why it was cut, if it was
    let silentGapSeconds: Double                               // take ended before the line did; that voice is silent there
    let overlappedLineIDs: [Int]                               // other characters' lines it runs over; both voices play
    var trimmedSeconds: Double; var isTrimNoticeable: Bool
}
```

Rules, stated once:
- A take starts exactly at its line's start. The cue plays from `cueStart` (1.5 s before the line, never before 0) to the line start with the original audio, then recording runs over `recordingWindow` while the video rolls silently.
- Raw clips: a take may run to the line end plus 0.75 s grace, but never into the next line of anyone or past the section end; the studio records to the grace end and export reports any cut.
- Curated scenes: a take may run to the line end plus grace, never into the same character's next line or past the scene end; the studio records exactly that window, so nothing recorded is dropped. Running over another character's line is kept and reported in `overlappedLineIDs`.
- A take shorter than its line leaves the rest of the line silent for that character (`silentGapSeconds`); the actor's original is not brought back mid-line.

## Take lifecycle

```swift
nonisolated enum TakeInputSource: Hashable, Sendable {
    case microphone
    case fixture(name: String)                 // -DUBBY_AUDIO_FIXTURE <name>, DEBUG or DUBBY_QA builds only
    var isSynthetic: Bool
    static var configured: TakeInputSource     // what this process records from
}
nonisolated struct RecordedTake {              // url and duration unchanged
    let inputSource: TakeInputSource           // show fixtureInputBadge when .fixture; never assess a fixture take
}
nonisolated struct TakeBook {                  // value type state machine
    private(set) var kept: [Int: RecordedTake]
    private(set) var candidates: [Int: RecordedTake]
    private(set) var inFlight: InFlightTake?
    func latestTake(lineID: Int) -> RecordedTake?   // candidate if one waits, else kept
}
nonisolated enum TakeSessionActivity { case idle, requestingPermission(lineID:), cue(lineID:), recording(lineID:) }
nonisolated enum TakeAttemptOutcome {
    case candidate(lineID:)                    // waits for keep or discard
    case cancelled(lineID:)
    case failed(lineID:, error: DubFlowError)  // .microphoneDenied, .recordingFailed, .audioFixtureMissing, ...
    case interrupted(lineID:, StudioInterruption)
}
nonisolated enum StudioInterruption { case audioSessionInterrupted, audioRouteLost, appBackgrounded; var reason: String }

@MainActor @Observable final class TakeSession {
    convenience init(setup: DubSetup)          // configured input, system permission and audio session
    let setup: DubSetup
    let player: SegmentPlayer                  // show player.player in PlayerSurface
    private(set) var activity: TakeSessionActivity
    private(set) var book: TakeBook
    private(set) var lastOutcome: TakeAttemptOutcome?
    var inputSource: TakeInputSource
    var keptTakes: [Int: RecordedTake]         // pass to export
    func observeSystemEvents()                 // interruptions, route loss, backgrounding
    func record(_ line: ScriptLine) async      // cue, record, end in an outcome; no-op unless idle
    func stopRecording()                       // ends early; what was recorded becomes the candidate
    func cancelRecording()                     // ends without a take
    func interrupt(_ reason: StudioInterruption)
    func keepCandidate(lineID: Int)            // the only call that replaces a kept take
    func discardCandidate(lineID: Int)
    func close()                               // stops capture and playback, releases the audio session
}
```

Guarantees: cancel, failure, interruption, route loss, backgrounding, task cancellation and microphone denial end the attempt without touching the kept take or an existing candidate, and delete the in-flight file. A finished attempt is a candidate; only `keepCandidate` replaces the kept take. The microphone permission is requested for fixture input too, and a denial fails the same way. `TakeRecorder` (existing) also honours the fixture, so the current studio gets fixture input without changes; `RecordedTake(url:duration:)` records the configured source.

**Original take file for assessment:** `RecordedTake.url`, an AAC `.m4a` in `setup.clip.workingDirectory` named `take-<lineIndex>-<uuid>.m4a`. The engine never modifies it; export reads it and assessment encodes a copy. Skip assessment when `inputSource.isSynthetic`.

## Preview and export

```swift
nonisolated enum DubProduction {
    @concurrent static func makeTimeline(setup: DubSetup, takes: [Int: RecordedTake]) async throws -> DubTimeline
    @concurrent static func render(_ timeline: DubTimeline, to output: URL) async throws -> DubExportReport   // export + verify
}
nonisolated enum DubRenderer {
    static func makePreviewItem(for timeline: DubTimeline) async throws -> AVPlayerItem    // same tracks and mix as export
    @concurrent static func export(_ timeline: DubTimeline, to output: URL) async throws  // cancellable; removes partial output
    @concurrent static func verifyExport(at url: URL, expectedDuration: Double) async throws -> DubExportReport
}
nonisolated struct DubTimeline: Hashable, Sendable { let duration: Double; let video: TimelineVideo; let audio: [TimelineAudioLayer]; let decisions: [TakeDecision] }
nonisolated enum DubExportError: LocalizedError { case overlappingClips, notPlayable, unexpectedTracks(video:audio:), audioNotAAC, outOfSync(video:audio:expected:) }
```

Export phases for the view: `makeTimeline` (instant for curated scenes; for raw clips it writes the speech-band-filtered copy, the existing "filtering dialogue" phase), then `render` (mixing and checking). Show a dub as finished only after `render` returns a report. Trim, gap and overlap notices come from `timeline.decisions`.

**Selective mix for a curated scene:** background at full volume throughout; every other character's dialogue track at full volume throughout; the played character's original dialogue everywhere no kept take covers it; the kept takes at their placements. Under a take the played character's original is muted from 0.12 s before the line to 0.12 s after the later of the line end and the take end, never reaching into that character's neighbouring lines. Nothing else is muted.

**Raw clips** keep the speech-band filter: under each take the original mix crossfades to a copy with roughly 420–3,400 Hz removed. This is an approximation, not dialogue separation.

The exported MP4 has one H.264 video track and one AAC audio track; `verifyExport` checks that picture and sound each last the timeline within one video frame.
