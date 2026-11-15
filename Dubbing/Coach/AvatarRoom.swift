import Foundation
import LiveKit

/// What the LiveKit room reports, handed from LiveKit's threads to the main actor.
nonisolated enum AvatarRoomUpdate: Sendable {
    case videoTrack(RemoteVideoTrack?)
    case event(LiveAvatarEvent)
    case unreadableEvent(String)
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

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard participant.identity?.stringValue == LiveAvatarEvent.avatarParticipantIdentity,
              let track = publication.track as? RemoteVideoTrack else { return }
        continuation.yield(.videoTrack(track))
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        guard participant.identity?.stringValue == LiveAvatarEvent.avatarParticipantIdentity,
              publication.kind == .video else { return }
        continuation.yield(.videoTrack(nil))
    }

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == LiveAvatarEvent.topic else { return }
        do {
            if let event = try LiveAvatarEvent.decode(data) {
                continuation.yield(.event(event))
            }
        } catch {
            continuation.yield(.unreadableEvent(error.localizedDescription))
        }
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        continuation.yield(.disconnected(error?.localizedDescription))
        continuation.finish()
    }
}

/// The LiveKit room that carries the avatar's video and audio, and our speak commands to it.
@MainActor
final class AvatarRoom {
    private let delegate = AvatarRoomDelegate()
    private let room: Room

    var updates: AsyncStream<AvatarRoomUpdate> { delegate.updates }

    init() {
        room = Room(delegate: delegate)
    }

    /// Joins as a listener only: the learner's mic is never published, so the avatar hears nothing
    /// and only says what `speak` sends.
    func connect(to connection: LiveAvatarConnection) async throws {
        // The coach records the learner with AVAudioRecorder while the avatar plays, so the app owns
        // the audio session instead of letting LiveKit switch categories underneath the recorder.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        try StudioAudioSession.activate()
        try await room.connect(url: connection.livekitURL, token: connection.livekitClientToken)
    }

    func speak(_ text: String) async throws {
        try await publish(try LiveAvatarCommand.speakText(text, eventID: UUID()))
    }

    func interrupt() async throws {
        try await publish(try LiveAvatarCommand.interrupt())
    }

    func disconnect() async {
        await room.disconnect()
    }

    private func publish(_ data: Data) async throws {
        try await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: LiveAvatarCommand.topic, reliable: true))
    }
}
