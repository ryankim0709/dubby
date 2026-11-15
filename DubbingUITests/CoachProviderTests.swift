import XCTest

@MainActor
final class CoachProviderTests: DubbingUITestCase {
    private func launchCoach(fault: String?) throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DUBBY_QA_COACH_DEV"] == "1",
            "Blocked: needs a Convex development deployment with the backend OpenAI key configured, a test identity, and an app built with COACH_BACKEND_URL pointing at it (Convex Backend DUBB-4, Tutoring DUBB-3). Run with TEST_RUNNER_DUBBY_QA_COACH_DEV=1 once it exists."
        )
        if let fault {
            app.launchArguments += ["-DUBBY_QA_COACH_FAULT", fault]
        }
        app.launch()
        tap("talkToCoach")
        tap("coachTalk")
    }

    func testReplyComesFromOpenAIAndAvatarSpeaksExactlyThatText() throws {
        try launchCoach(fault: nil)
        _ = requireElement("coachReplyText", timeout: 60)
        let provenance = value(of: "coachReplyProvenance") ?? ""
        XCTAssertTrue(provenance.hasPrefix("openai/"), "Reply provenance must name OpenAI, got \"\(provenance)\"")
        XCTAssertEqual(value(of: "coachAvatarSpeech"), value(of: "coachReplyText"), "LiveAvatar must speak exactly the backend's reply")
    }

    func testMissingKeyShowsAnHonestErrorWithRetry() throws {
        try launchCoach(fault: "missing_key")
        _ = requireElement("coachError", timeout: 60)
        XCTAssertEqual(value(of: "coachError"), "not_configured")
        XCTAssertFalse(element("coachReplyText").exists, "No reply may be shown when the provider is not configured")
        _ = requireElement("coachRetry")
    }

    func testProviderErrorAndTimeoutShowErrorsAndRetryRecovers() throws {
        try launchCoach(fault: "provider_error")
        _ = requireElement("coachError", timeout: 60)
        XCTAssertEqual(value(of: "coachError"), "provider_failed")
        XCTAssertFalse(element("coachReplyText").exists)
        let spoken = value(of: "coachAvatarSpeech")
        XCTAssertNil(spoken, "The avatar must not speak while the provider failed")
        capture("provider-error")
        tap("coachRetry")
        _ = requireElement("coachError", timeout: 60)
        XCTAssertEqual(value(of: "coachError"), "provider_failed", "With the fault still on, retry must fail again honestly, not invent a reply")
    }

    func testTranscriptAgreementIsNeverShownAsAPronunciationScore() throws {
        try launchCoach(fault: nil)
        let basis = value(of: "feedbackBasis") ?? "none"
        if basis != "acoustic" {
            XCTAssertFalse(element("pronunciationScore").exists, "A \(basis) basis must not show a pronunciation score")
        }
    }
}
