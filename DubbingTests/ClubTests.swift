import Foundation
import Testing
@testable import Dubbing

struct ClubTests {
    @Test func uploadValidationReadsTheMediaBeforeSharing() async throws {
        let video = try TestFixtures.twoToneVideo()
        let draft = ClubMediaDraft(url: video, kind: .video, title: "Synthetic performance", replyToMessageId: nil)
        #expect(try await ClubClient.validate(draft) > 0)
        let wrongKind = ClubMediaDraft(url: video, kind: .voice, title: "Synthetic feedback", replyToMessageId: "post_fixture")
        await #expect(throws: ClubError.self) { try await ClubClient.validate(wrongKind) }
    }

    @Test func voiceFeedbackStaysWithItsPerformance() throws {
        let url = try #require(URL(string: "https://example.com/synthetic.mp4"))
        let performance = ClubPost(id: "post_video", authorId: "user_one", authorName: "One", caption: "", createdAt: "2026-11-15T00:00:00Z", replyToMessageId: nil, kind: .video, mediaURL: url, durationSeconds: 3)
        let feedback = ClubPost(id: "post_voice", authorId: "user_two", authorName: "Two", caption: "", createdAt: "2026-11-15T00:00:01Z", replyToMessageId: performance.id, kind: .voice, mediaURL: url, durationSeconds: 2)
        let unrelated = ClubPost(id: "post_other", authorId: "user_two", authorName: "Two", caption: "", createdAt: "2026-11-15T00:00:02Z", replyToMessageId: "post_elsewhere", kind: .voice, mediaURL: url, durationSeconds: 2)
        let challenge = ClubChallenge(id: "synthetic", title: "Synthetic challenge", sceneId: "synthetic", sceneTitle: "Synthetic", prompt: "")
        let feed = ClubFeed(name: "Synthetic", challenge: challenge, viewerId: "user_one", members: [], posts: [performance, feedback, unrelated])
        #expect(feed.performances.map(\.id) == [performance.id])
        #expect(feed.feedback(for: performance).map(\.id) == [feedback.id])
    }
}
