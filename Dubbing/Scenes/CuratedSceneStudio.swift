import Foundation

/// A curated scene and the character the learner plays in it.
nonisolated struct CuratedSceneSelection: Hashable, Sendable {
    let scene: CuratedScene
    let characterID: SceneCharacter.ID
    /// The played character's speaker id in the studio script: speaker ids are character positions in the manifest.
    let speakerID: Int

    init(scene: CuratedScene, characterID: SceneCharacter.ID) throws {
        guard let index = scene.characters.firstIndex(where: { $0.id == characterID }) else {
            throw SceneValidationError.characterNotInScene(characterID)
        }
        self.scene = scene
        self.characterID = characterID
        speakerID = index
    }

    /// The scene's lines as studio script lines. A line's local id is its position in the manifest, and its
    /// `reference` carries the manifest line id, character id, locale and reference version.
    func scriptLines(envelopes: [Int: [Float]]) -> [ScriptLine] {
        scene.lines.enumerated().map { index, line in
            ScriptLine(
                id: index,
                text: line.text,
                start: line.start,
                end: line.end,
                speakerID: scene.characters.firstIndex { $0.id == line.characterID } ?? 0,
                envelope: envelopes[index] ?? [],
                reference: LineReference(lineID: line.id, characterID: line.characterID, locale: line.locale, referenceVersion: line.referenceVersion)
            )
        }
    }

    /// The manifest line behind a studio line.
    func sceneLine(for line: ScriptLine) -> SceneLine? {
        line.reference.flatMap { reference in scene.lines.first { $0.id == reference.lineID } }
    }
}

/// Turns a curated scene and a chosen character into the studio's setup, straight from the manifest: no
/// transcription, no voice grouping, no section framing.
nonisolated enum CuratedSceneStudio {
    /// Waveform bars come from each character's own dialogue track, so a line's waveform shows only that voice.
    @concurrent
    static func makeSetup(scene: CuratedScene, characterID: SceneCharacter.ID, barCount: Int, workingDirectory: URL) async throws -> DubSetup {
        let selection = try CuratedSceneSelection(scene: scene, characterID: characterID)
        var envelopes: [Int: [Float]] = [:]
        for character in scene.characters {
            let audio = try MediaPipeline.readMonoAudio(from: character.dialogueURL)
            for (index, line) in scene.lines.enumerated() where line.characterID == character.id {
                let lower = min(audio.samples.count, max(0, Int(line.start * audio.sampleRate)))
                let upper = min(audio.samples.count, max(lower, Int(line.end * audio.sampleRate)))
                envelopes[index] = ScriptBuilder.envelope(samples: Array(audio.samples[lower..<upper]), barCount: barCount)
            }
        }
        let speakers = scene.characters.enumerated().map { Speaker(id: $0.offset, name: $0.element.displayName) }
        return DubSetup(
            clip: ImportedClip(url: scene.videoURL, title: scene.title, durationSeconds: scene.durationSeconds, origin: .bundled, workingDirectory: workingDirectory),
            script: Script(lines: selection.scriptLines(envelopes: envelopes), speakers: speakers),
            curated: selection
        )
    }

    /// A fresh working folder for one curated dub's takes and exports.
    static func newWorkingDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "DubProjects/\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
