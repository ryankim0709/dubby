import Foundation

/// Film names, one-line scene descriptions, cast, and spoken language for the published library.
/// The backend's scene records carry none of these, so they are kept here by scene slug until it does.
nonisolated enum SceneBlurbs {
    struct Entry {
        let film: String
        let blurb: String
        let cast: [String]
        /// The spoken language the backend stored for the scene; its catalog response doesn't include it yet.
        let locale: String
    }

    static let entries: [String: Entry] = [
        "anakin-confronts-obi-wan": Entry(film: "Star Wars: Revenge of the Sith", blurb: "Anakin turns on his master.", cast: ["Anakin Skywalker", "Obi-Wan Kenobi"], locale: "en-US"),
        "business-proposal-samantha-and-rachel": Entry(film: "Business Proposal", blurb: "A friend begs her to take a blind date.", cast: ["Samantha", "Rachel"], locale: "ko-KR"),
        "its-okay-to-not-be-okay-i-love-you": Entry(film: "It’s Okay to Not Be Okay", blurb: "A guarded confession finally slips out.", cast: ["Ko Moon-young", "Moon Gang-tae"], locale: "ko-KR"),
        "money-heist-professor-meets-tokyo": Entry(film: "Money Heist", blurb: "The Professor recruits Tokyo.", cast: ["The Professor", "Tokyo"], locale: "es-ES"),
        "your-name-final-staircase": Entry(film: "Your Name", blurb: "Two strangers pass on a staircase.", cast: ["Taki", "Mitsuha"], locale: "ja-JP"),
        "death-note-potato-chip-monologue": Entry(film: "Death Note", blurb: "Light hides a kill behind a bag of chips.", cast: ["Light Yagami"], locale: "ja-JP"),
        "you-can-see-everything-elizabeth-holmes-interview": Entry(film: "You Can See Everything", blurb: "Elizabeth Holmes pitches her vision.", cast: ["Elizabeth Holmes"], locale: "en-US"),
        "wild-tales-rooftop-confrontation": Entry(film: "Wild Tales", blurb: "A rooftop standoff boils over.", cast: [], locale: "es-ES"),
    ]
}

extension LibraryClip {
    /// The film or show the scene comes from.
    var filmTitle: String { SceneBlurbs.entries[sceneID]?.film ?? sourceTitle }

    /// A very short description of what happens in the scene, when one is known.
    var blurb: String? { SceneBlurbs.entries[sceneID]?.blurb }

    /// Who appears in the scene, for the preview before its script has been built.
    var castNames: [String] { SceneBlurbs.entries[sceneID]?.cast ?? [] }
}
