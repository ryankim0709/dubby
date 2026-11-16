import Foundation
import Testing
@testable import Dubbing

struct SimliTests {
    @Test func convertsRealtimeAudioWithoutChangingItsDurationOrPitch() throws {
        let pcm = tone()
        let converted = try SimliAudio.resample(realtimePCM: pcm)
        #expect(abs(converted.count / 2 - 16_000) <= 1)
        let samples = LiveTutorRealtime.samples(fromPCM16: converted)
        let crossings = zip(samples, samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        #expect(abs(crossings - 440) <= 1)
        #expect((samples.max() ?? 0) > 0.45)
        #expect(throws: CoachError.self) { try SimliAudio.resample(realtimePCM: Data([1])) }
        #expect(throws: CoachError.self) { try SimliAudio.resample(realtimePCM: Data()) }
        #expect(throws: CoachError.self) { try SimliAudio.resample(realtimePCM: Data(count: 60 * 48_000 + 2)) }
    }

    @Test func followsTheComposeHandshakeAndSendsBinaryAudioThenInterruptsAndCloses() async throws {
        let transport = FixtureTransport()
        let socket = SimliAvatarSocket(transport: transport)
        await socket.start()
        var events = socket.events.makeAsyncIterator()
        await transport.feed(#"{"destination":"fixture","session_id":"fixture-session"}"#)
        await transport.feed(#"{"livekit_url":"wss://fixture.livekit.cloud","livekit_token":"fixture-room-token"}"#)
        #expect(await events.next() == .room(SimliRoomConnection(url: "wss://fixture.livekit.cloud", token: "fixture-room-token")))
        await #expect(throws: CoachError.avatarDisconnected) { try await socket.speak(realtimePCM: tone()) }
        await transport.feed("START")
        #expect(await events.next() == .ready)
        try await socket.speak(realtimePCM: tone())
        let chunks = await transport.audio
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 6_000 && $0.count.isMultiple(of: 2) })
        #expect(abs(chunks.reduce(0) { $0 + $1.count } - 32_000) <= 2)
        await transport.feed("SPEAK")
        #expect(await events.next() == .speaking)
        try await socket.interrupt()
        #expect(await transport.commands == ["SKIP"])
        await transport.feed("SILENT")
        #expect(await events.next() == .silent)
        await socket.close()
        #expect(await transport.isClosed)
        #expect(await events.next() == nil)
        await #expect(throws: CoachError.avatarDisconnected) { try await socket.speak(realtimePCM: tone()) }
    }

    @Test func providerErrorsAndMalformedRoomDetailsEndTheVideoInsteadOfReportingReady() async throws {
        #expect(try SimliAvatarEvent.decode("ACK") == nil)
        #expect(try SimliAvatarEvent.decode(#"{"video_metadata":{"fps":25,"width":768,"height":768}}"#) == nil)
        #expect(throws: CoachError.self) { try SimliAvatarEvent.decode(#"{"livekit_url":"https://fixture.test","livekit_token":"token"}"#) }
        #expect(throws: CoachError.self) { try SimliAvatarEvent.decode(#"{"livekit_url":"wss://fixture.test"}"#) }
        let transport = FixtureTransport()
        let socket = SimliAvatarSocket(transport: transport)
        await socket.start()
        var events = socket.events.makeAsyncIterator()
        await transport.feed("ERROR: SESSION_TOKEN_EXPIRED")
        guard case .closed(let reason) = await events.next() else {
            Issue.record("A rejected Simli session must close with its reason")
            return
        }
        #expect(reason?.contains("SESSION_TOKEN_EXPIRED") == true)
        #expect(await events.next() == nil)
        #expect(await transport.isClosed)
    }

    private func tone() -> Data {
        let samples: [Int16] = (0..<24_000).map { index in
            Int16(sin(2 * Double.pi * 440 * Double(index) / 24_000) * Double(Int16.max) * 0.5)
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private actor FixtureTransport: SimliSocketTransport {
        private(set) var audio: [Data] = []
        private(set) var commands: [String] = []
        private(set) var isClosed = false
        private var pending: [String] = []
        private var waiter: CheckedContinuation<String, any Error>?

        func send(_ text: String) { commands.append(text) }
        func send(_ data: Data) { audio.append(data) }

        func feed(_ text: String) {
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: text)
            } else {
                pending.append(text)
            }
        }

        func receive() async throws -> String {
            if !pending.isEmpty { return pending.removeFirst() }
            if isClosed { throw CoachError.avatarDisconnected }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }

        func close() {
            isClosed = true
            waiter?.resume(throwing: CoachError.avatarDisconnected)
            waiter = nil
        }
    }
}
