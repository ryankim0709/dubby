import Foundation
import LiveKit

/// What the LiveKit room reports, handed from LiveKit's threads to the main actor.
nonisolated enum AvatarRoomUpdate: Sendable {
    case videoTrack(RemoteVideoTrack?)
    case disconnected(String?)
}

/// Forwards LiveKit delegate callbacks, which arrive on arbitrary threads, into an async stream.
nonisolated private final class AvatarRoomDelegate: NSObject, RoomDelegate {
    let updates: AsyncStream<AvatarRoomUpdate>
    private let continuation: AsyncStream<AvatarRoomUpdate>.Continuation

    override init() {
        (updates, continuation) = AsyncStream.makeStream()
        super.init()
    }

    /// The learner publishes nothing to this room, so the only video in it is the avatar's.
    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track as? RemoteVideoTrack else { return }
        continuation.yield(.videoTrack(track))
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        guard publication.kind == .video else { return }
        continuation.yield(.videoTrack(nil))
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        continuation.yield(.disconnected(error?.localizedDescription))
        continuation.finish()
    }
}

/// The LiveKit room that carries the avatar's video and audio. The app only listens: it publishes
/// no microphone and sends no data, because the coach's voice goes to LiveAvatar over its socket.
@MainActor
final class AvatarRoom {
    private let delegate = AvatarRoomDelegate()
    private let room: Room

    var updates: AsyncStream<AvatarRoomUpdate> { delegate.updates }

    init() {
        room = Room(delegate: delegate)
    }

    func connect(to connection: LiveAvatarConnection) async throws {
        // The coach records the learner with AVAudioRecorder while the avatar plays, so the app owns
        // the audio session instead of letting LiveKit switch categories underneath the recorder.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        try StudioAudioSession.activate()
        try await room.connect(url: connection.livekitURL, token: connection.livekitClientToken)
    }

    func disconnect() async {
        await room.disconnect()
    }
}
