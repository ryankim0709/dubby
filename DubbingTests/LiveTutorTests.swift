import Foundation
import Testing
@testable import Dubbing

// Every frame here is a synthetic fixture shaped like OpenAI's Realtime GA events; no service is called.

struct LiveTutorTests {
    @Test @MainActor func speechFailurePreservesAnAISuggestion() {
        let takeID = UUID()
        let suggestion = TakeCoach.Suggestion(suggestion: .retry, tip: "Give the final word a little more space.")
        let answered = TakeCoach.Review(takeID: takeID, state: .suggested(suggestion))
        #expect(answered.failing(reason: "speaker unavailable") == answered)
        let listening = TakeCoach.Review(takeID: takeID, state: .listening)
        #expect(listening.failing(reason: "socket closed") == TakeCoach.Review(takeID: takeID, state: .unavailable("socket closed")))
    }

    @Test func referencePitchMeasuresVoiceRegisterAndRejectsSilence() {
        for frequency in [120.0, 220.0, 300.0] {
            let samples = (0..<16_000).map { Float(sin(2 * Double.pi * frequency * Double($0) / 16_000)) * 0.5 }
            let pitch = VoicePrint.pitchHz(samples: samples, sampleRate: 16_000)
            #expect(abs((pitch ?? 0) - frequency) < 10)
        }
        #expect(VoicePrint.pitchHz(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000) == nil)
        #expect(VoicePrint.pitchHz(samples: [], sampleRate: 16_000) == nil)
    }

    @Test func decodesTheRealtimeEventsTheTutorFollowsAndSkipsTheRest() throws {
        func decode(_ json: String) throws -> LiveTutorServerEvent? {
            try LiveTutorServerEvent.decode(json)
        }
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F])
        #expect(try decode(#"{"type":"session.created","event_id":"e1","session":{"type":"realtime"}}"#) == .sessionCreated)
        #expect(try decode(#"{"type":"input_audio_buffer.speech_started","item_id":"u1","audio_start_ms":120}"#) == .learnerStartedSpeaking(itemID: "u1"))
        #expect(try decode(#"{"type":"response.output_audio.delta","item_id":"t1","content_index":0,"output_index":0,"response_id":"r","delta":"\#(pcm.base64EncodedString())"}"#)
            == .tutorAudio(responseID: "r", itemID: "t1", contentIndex: 0, pcm: pcm))
        #expect(try decode(#"{"type":"response.created","response":{"id":"r2","status":"in_progress","metadata":{"review":"take-1"}}}"#)
            == .responseCreated(responseID: "r2", reviewID: "take-1"))
        #expect(try decode(#"{"type":"response.function_call_arguments.done","response_id":"r2","item_id":"f","output_index":0,"call_id":"c1","name":"suggest_next_step","arguments":"{}"}"#)
            == .toolCall(responseID: "r2", callID: "c1", name: "suggest_next_step", arguments: "{}"))
        #expect(try decode(#"{"type":"response.done","response":{"id":"r2","status":"completed","output":[]}}"#) == .responseDone(responseID: "r2"))
        // An event the tutor ignores is skipped even when its fields are shaped unlike the ones it reads.
        #expect(try decode(#"{"type":"conversation.item.added","item":{"id":"i"},"response":"not an object"}"#) == nil)
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
        let audio = Data([1, 2]).base64EncodedString()
        #expect(try object(LiveTutorClientEvent.take(note: "The line: Hola.", pcm: Data([1, 2])))
            == object(#"{"type":"conversation.item.create","item":{"type":"message","role":"user","content":[{"type":"input_text","text":"The line: Hola."},{"type":"input_audio","audio":"\#(audio)"}]}}"#))
        #expect(try object(LiveTutorClientEvent.requestToolCall(named: "suggest_next_step", reviewID: "take-1"))
            == object(#"{"type":"response.create","response":{"output_modalities":["text"],"tool_choice":{"type":"function","name":"suggest_next_step"},"metadata":{"review":"take-1"}}}"#))
        #expect(try object(LiveTutorClientEvent.requestSpeech(reviewID: "take-1"))
            == object(#"{"type":"response.create","response":{"output_modalities":["audio"],"tool_choice":"none","metadata":{"review":"take-1"}}}"#))
        #expect(try object(LiveTutorClientEvent.toolResult(callID: "c1", output: "Shown."))
            == object(#"{"type":"conversation.item.create","item":{"type":"function_call_output","call_id":"c1","output":"Shown."}}"#))
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

    @Test func takeTimingComparesTheVoiceWithTheLine() {
        // SYNTHETIC takes: silence with a 220 Hz tone where the learner "speaks", at 16 kHz.
        func take(voiceFrom start: Double, to end: Double, length: Double) -> [Float] {
            (0..<Int(length * 16_000)).map { index in
                let time = Double(index) / 16_000
                return time >= start && time < end ? Float(sin(2 * Double.pi * 220 * time)) * 0.5 : 0
            }
        }
        func assess(_ samples: [Float]) -> TakeTiming {
            TakeTiming.assess(samples: samples, sampleRate: 16_000, lineDuration: 1.0)
        }
        #expect(assess(take(voiceFrom: 0.1, to: 1.1, length: 1.5)) == .onCue)
        #expect(assess(take(voiceFrom: 0, to: 1.0, length: 1.5)) == .early)
        #expect(assess(Array(repeating: 0, count: 24_000)) == .noVoice)
        guard case .late(let late) = assess(take(voiceFrom: 0.5, to: 1.4, length: 1.5)) else { Issue.record("expected late"); return }
        #expect(abs(late - 0.5) < 0.03)
        guard case .long(let long) = assess(take(voiceFrom: 0.1, to: 1.8, length: 2.0)) else { Issue.record("expected long"); return }
        #expect(abs(long - 0.8) < 0.03)
        guard case .short(let short) = assess(take(voiceFrom: 0.1, to: 0.3, length: 1.5)) else { Issue.record("expected short"); return }
        #expect(abs(short - 0.7) < 0.03)
    }
}
