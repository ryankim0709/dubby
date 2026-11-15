import Foundation
import Testing
@testable import Dubbing

struct CoachTests {
    @Test func speakTextMatchesTheWebSDKCommandShape() throws {
        let eventID = UUID()
        let data = try LiveAvatarCommand.speakText("Hola, ¿qué tal?", eventID: eventID)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json == ["event_id": eventID.uuidString.lowercased(), "event_type": "avatar.speak_text", "text": "Hola, ¿qué tal?"])
    }

    @Test func decodesTheAvatarEventsTheCoachFollowsAndSkipsTheRest() throws {
        func decode(_ json: String) throws -> LiveAvatarEvent? {
            try LiveAvatarEvent.decode(Data(json.utf8))
        }
        #expect(try decode(#"{"event_id":"1","event_type":"avatar.speak_started","session_id":"s"}"#) == .avatarStartedSpeaking)
        #expect(try decode(#"{"event_type":"avatar.speak_ended","session_id":"s","source_event_id":null}"#) == .avatarStoppedSpeaking)
        #expect(try decode(#"{"event_type":"session.stopped","stop_reason":"IDLE_TIMEOUT"}"#) == .sessionStopped(reason: "IDLE_TIMEOUT"))
        #expect(try decode(#"{"event_type":"user.transcription","text":"hi"}"#) == nil)
        #expect(throws: DecodingError.self) { try decode(#"{"text":"no type"}"#) }
    }

    @Test func sendsOnlyTranscriptsThatHoldWords() {
        let words = [TranscribedWord(text: "Me", start: 0, end: 0.2), TranscribedWord(text: "llamo", start: 0.2, end: 0.5)]
        #expect(CoachConversation.learnerText(from: words) == "Me llamo")
        #expect(CoachConversation.learnerText(from: []) == nil)
    }

    @Test func avatarLanguageDropsTheRegion() {
        let languages = SpokenLanguage.all.map(CoachConversation.avatarLanguageCode(for:))
        #expect(languages == ["en", "ko", "ja", "es", "fr", "de", "zh"])
    }
}
