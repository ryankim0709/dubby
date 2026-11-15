import Foundation
import Testing
@testable import Dubbing

// Every frame here is a synthetic fixture shaped like OpenAI's Realtime GA events; no service is called.

struct LiveTutorTests {
    @Test func decodesTheRealtimeEventsTheTutorFollowsAndSkipsTheRest() throws {
        func decode(_ json: String) throws -> LiveTutorServerEvent? {
            try LiveTutorServerEvent.decode(json)
        }
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F])
        #expect(try decode(#"{"type":"session.created","event_id":"e1","session":{"type":"realtime"}}"#) == .sessionCreated)
        #expect(try decode(#"{"type":"input_audio_buffer.speech_started","item_id":"u1","audio_start_ms":120}"#) == .learnerStartedSpeaking(itemID: "u1"))
        #expect(try decode(#"{"type":"response.output_audio.delta","item_id":"t1","content_index":0,"output_index":0,"response_id":"r","delta":"\#(pcm.base64EncodedString())"}"#)
            == .tutorAudio(itemID: "t1", contentIndex: 0, pcm: pcm))
        #expect(try decode(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u1","content_index":0,"transcript":"hola"}"#)
            == .learnerTranscript(itemID: "u1", text: "hola"))
        #expect(try decode(#"{"type":"error","error":{"type":"invalid_request_error","code":"response_cancel_not_active","message":"nothing to cancel"}}"#)
            == .failed(code: "response_cancel_not_active", message: "nothing to cancel"))
        #expect(try decode(#"{"type":"rate_limits.updated","rate_limits":[]}"#) == nil)
        #expect(throws: CoachError.self) { try decode(#"{"type":"response.output_audio.delta","item_id":"t1","content_index":0}"#) }
        #expect(throws: CoachError.self) { try decode(#"{"type":"response.output_audio.delta","item_id":"t1","content_index":0,"delta":"not base64!"}"#) }
    }

    @Test func clientEventsHaveTheRealtimeShape() throws {
        func object(_ frame: String) throws -> NSDictionary {
            try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? NSDictionary)
        }
        #expect(try object(LiveTutorClientEvent.appendAudio(Data([1, 2]))) == ["type": "input_audio_buffer.append", "audio": Data([1, 2]).base64EncodedString()])
        #expect(try object(LiveTutorClientEvent.createResponse()) == ["type": "response.create"])
        #expect(try object(LiveTutorClientEvent.truncate(itemID: "t1", contentIndex: 0, audioEndMs: 1500))
            == ["type": "conversation.item.truncate", "item_id": "t1", "content_index": 0, "audio_end_ms": 1500])
    }

    @Test func learnerLinesKeepTheirPlaceWhenTheirTranscriptArrivesAfterTheTutorStartsAnswering() {
        let events: [LiveTutorServerEvent] = [
            .tutorTranscript(itemID: "t1", delta: "Repeat after "),
            .tutorTranscript(itemID: "t1", delta: "me."),
            .learnerStartedSpeaking(itemID: "u1"),
            .learnerStoppedSpeaking,
            .tutorTranscript(itemID: "t2", delta: "Better!"),
            .learnerTranscript(itemID: "u1", text: " Hola amigo "),
            .learnerStartedSpeaking(itemID: "u2"),
            .learnerTranscript(itemID: "u2", text: "  "),
        ]
        let transcript = events.reduce(LiveTutorTranscript.empty) { $0.applying($1) }
        #expect(transcript.lines.map(\.id) == ["t1", "u1", "t2"])
        #expect(transcript.lines.map(\.text) == ["Repeat after me.", "Hola amigo", "Better!"])
    }

    @Test func cuttingInReportsHowMuchOfTheReplyWasHeard() {
        let timeline = TutorPlaybackTimeline.idle
            .scheduling(itemID: "t1", contentIndex: 0, frames: 24_000, at: .seconds(10))
            .scheduling(itemID: "t1", contentIndex: 0, frames: 12_000, at: .seconds(10.2))
        #expect(timeline.endsAt == .seconds(11.5))
        #expect(timeline.heardMilliseconds(at: .seconds(10.75)) == 750)
        #expect(timeline.remaining(at: .seconds(11)) == .seconds(0.5))
        #expect(timeline.heardMilliseconds(at: .seconds(12)) == nil)

        // A new reply after a pause starts its own count from when its audio begins.
        let next = timeline.scheduling(itemID: "t2", contentIndex: 0, frames: 24_000, at: .seconds(20))
        #expect(next.current?.startsAt == .seconds(20))
        #expect(next.heardMilliseconds(at: .seconds(20.25)) == 250)
    }

    @Test func tutorAudioBecomesSamplesInRange() {
        let samples = LiveTutorRealtime.samples(fromPCM16: Data([0x00, 0x00, 0xFF, 0x7F, 0x01, 0x80, 0x07]))
        #expect(samples == [0, 1, -1])
    }

    @Test @MainActor func microphoneAudioIsResampledTo24kHzPCM16() throws {
        let encoder = try LiveTutorMicrophoneEncoder(inputSampleRate: 48_000)
        // A SYNTHETIC 440 Hz tone in 50 ms buffers, the size the microphone tap delivers.
        let buffers = (0..<20).map { buffer in
            (0..<2_400).map { index in Float(sin(2 * Double.pi * 440 * Double(buffer * 2_400 + index) / 48_000)) * 0.5 }
        }
        let encoded = try buffers.map { try encoder.encode($0) }
        let frames = encoded.reduce(0) { $0 + $1.count } / LiveTutorRealtime.bytesPerFrame
        // One second of input; the converter may hold back a few frames for its filter.
        #expect(abs(frames - 24_000) < 200)
        let samples = LiveTutorRealtime.samples(fromPCM16: encoded.reduce(Data(), +))
        #expect((samples.max() ?? 0) > 0.4)
    }
}
