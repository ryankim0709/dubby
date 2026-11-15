import Foundation
import Observation

/// A request to open the dubbing flow for a scene, optionally with the role fixed by a co-dub invite.
struct DubRequest: Hashable, Identifiable {
    let id: UUID
    let scene: SceneClip
    let lockedCharacterID: String?
    let partner: Friend?
}

/// App-wide state shared by the tabs: which scene is previewing, the active dub flow, and the
/// user's shelf and invites. Sample content stands in until the backend serves these.
@Observable
final class AppModel {
    var previewScene: SceneClip?
    var activeDub: DubRequest?
    private(set) var shelf: [ShelfDub] = SampleData.shelf
    private(set) var invites: [CoDubInvite] = SampleData.invites
    let feed: [FeedPost] = SampleData.feed
    let conversations: [Conversation] = SampleData.conversations
    let scenes: [SceneClip] = SampleData.scenes
    let me: Friend = SampleData.me

    /// Held while the preview sheet animates away; a full-screen cover can't present until it's gone.
    private var queuedDub: DubRequest?

    func preview(_ scene: SceneClip) {
        previewScene = scene
    }

    func startDub(scene: SceneClip, lockedCharacterID: String?, partner: Friend?) {
        let request = DubRequest(id: UUID(), scene: scene, lockedCharacterID: lockedCharacterID, partner: partner)
        if previewScene != nil {
            queuedDub = request
            previewScene = nil
        } else {
            activeDub = request
        }
    }

    func previewDidDismiss() {
        guard let queuedDub else { return }
        self.queuedDub = nil
        activeDub = queuedDub
    }

    func accept(_ invite: CoDubInvite) {
        invites.removeAll { $0.id == invite.id }
        startDub(scene: invite.scene, lockedCharacterID: invite.yourCharacterID, partner: invite.from)
    }

    func decline(_ invite: CoDubInvite) {
        invites.removeAll { $0.id == invite.id }
    }

    func file(_ summary: DubSummary, videoURL: URL, visibility: Visibility) {
        let scores = Array(summary.timingScores.values)
        let average = scores.isEmpty ? nil : scores.reduce(0, +) / scores.count
        let dub = ShelfDub(
            id: UUID().uuidString,
            scene: summary.scene,
            characterID: summary.characterID,
            collaborator: summary.partner,
            visibility: visibility,
            progress: .finished(timingScore: average),
            dateText: "Just now",
            videoURL: videoURL
        )
        shelf.insert(dub, at: 0)
    }

    func setVisibility(_ visibility: Visibility, for dubID: String) {
        guard let index = shelf.firstIndex(where: { $0.id == dubID }) else { return }
        shelf[index].visibility = visibility
    }
}
