import Foundation
import os

/// A hand-checked script for a published scene, bundled as `<scene id>-script.json` with a portrait per character.
/// A scene with one opens straight on role choice: nothing is transcribed or diarized while the learner waits,
/// and the lines and speakers are the ones a person confirmed against the film.
nonisolated struct PublishedSceneScript: Decodable, Sendable {
    struct Character: Decodable, Sendable {
        let name: String
        /// Seconds into the clip of the frame that shows this character best, for the role card.
        let portraitSeconds: Double
        let faceCenterX: Double
        /// Bundled JPEG resource name of the character's face.
        let portrait: String
    }

    struct Line: Decodable, Sendable {
        let text: String
        /// Seconds from the clip start.
        let start: Double
        let end: Double
        let character: Int
        /// Loudness bars of the original line, measured when the script was prepared.
        let envelope: [Float]
    }

    let characters: [Character]
    let lines: [Line]

    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "published-scene-script")

    /// The bundled script for a scene, or nil when the scene has none and must be transcribed.
    static func bundled(for sceneID: String, in bundle: Bundle = .main) -> PublishedSceneScript? {
        guard let url = bundle.url(forResource: "\(sceneID)-script", withExtension: "json") else { return nil }
        do {
            return try JSONDecoder().decode(PublishedSceneScript.self, from: Data(contentsOf: url))
        } catch {
            // A broken bundled script falls back to transcribing the scene, so the learner can still dub it.
            logger.error("The bundled script for \(sceneID, privacy: .public) couldn't be read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    var script: Script {
        Script(
            lines: lines.indices.map { index in
                ScriptLine(id: index, text: lines[index].text, start: lines[index].start, end: lines[index].end, speakerID: lines[index].character, envelope: lines[index].envelope)
            },
            speakers: characters.indices.map { Speaker(id: $0, name: characters[$0].name) }
        )
    }

    var cast: SceneCast {
        SceneCast(
            characters: characters.map { SceneCast.Character(name: $0.name, portraitSeconds: $0.portraitSeconds, faceCenterX: $0.faceCenterX) },
            segments: lines.map { SceneCast.Segment(start: $0.start, end: $0.end, character: $0.character) }
        )
    }

    func lineCount(of character: Int) -> Int {
        lines.count { $0.character == character }
    }

    func portraitURL(of character: Int, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: characters[character].portrait, withExtension: "jpg")
    }
}
