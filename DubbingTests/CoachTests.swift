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

    // MARK: Tutoring models

    private func decodeReply(_ json: String) throws -> CoachReply {
        try JSONDecoder().decode(CoachReply.self, from: Data(json.utf8))
    }

    @Test func aReplyFromBeforeTheTutoringFieldsStillDecodes() throws {
        let reply = try decodeReply(#"{"text":"Nice work."}"#)
        #expect(reply.text == "Nice work.")
        #expect(reply.source == nil)
        #expect(reply.feedbackBasis == .none)
        #expect(reply.citedEvidenceIds.isEmpty)
        #expect(reply.exercise == nil)
    }

    @Test func aTutoringReplyDecodesItsBasisEvidenceAndExercise() throws {
        let reply = try decodeReply("""
        {"text":"Slow down on 'underestimate'.","source":"template","feedbackBasis":"script_agreement",
         "citedEvidenceIds":["take_003"],"unrelated":true,
         "exercise":{"kind":"drill_word","locale":"en-US","lineId":"line_02","referenceVersion":1,
           "practiceText":"underestimate","focus":"word_accuracy","instruction":"Say it slowly.",
           "reasonCode":"recurring_word","evidence":{"attemptIds":["take_003"],"assessmentIds":["a_1"]}}}
        """)
        #expect(reply.source == .template)
        #expect(reply.feedbackBasis == .scriptAgreement)
        #expect(reply.citedEvidenceIds == ["take_003"])
        #expect(reply.exercise?.kind == .drillWord)
        #expect(reply.exercise?.focus == .wordAccuracy)
        #expect(reply.exercise?.evidence.attemptIds == ["take_003"])
    }

    @Test func anUnknownFeedbackBasisIsNeverShownAsMeasured() throws {
        let reply = try decodeReply(#"{"text":"Hi","feedbackBasis":"phoneme_lab"}"#)
        #expect(reply.feedbackBasis == .none)
        #expect(reply.feedbackBasis.display(citedEvidenceCount: 0) == nil)
    }

    @Test func scriptAgreementIsLabelledDifferentlyFromAcousticMeasurement() throws {
        let acoustic = try #require(FeedbackBasis.acoustic.display(citedEvidenceCount: 2))
        let script = try #require(FeedbackBasis.scriptAgreement.display(citedEvidenceCount: 0))
        #expect(acoustic.title != script.title)
        #expect(acoustic.detail.contains("2"))
        #expect(!script.title.localizedCaseInsensitiveContains("pronunciation"))
    }

    @Test func anAcousticClaimWithNoCitedResultIsNotLabelledAsMeasured() {
        #expect(FeedbackBasis.acoustic.display(citedEvidenceCount: 0) == nil)
    }

    @Test func preferencesRoundTripAndOmitUnsetValues() throws {
        var preferences = CoachPreferences.standard
        preferences.sessionMinutes = .ten
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        #expect(json["sessionMinutes"] as? Int == 10)
        #expect(json["goalNote"] == nil)
        #expect(json["focus"] as? String == "any")
        let record = try JSONDecoder().decode(CoachPreferencesRecord.self, from: Data(#"{"preferences":{"focus":"word_accuracy","challenge":"stretch","avoidLineIds":["l1"],"goalNote":"Order food"},"version":3}"#.utf8))
        #expect(record.version == 3)
        #expect(record.preferences.focus == .wordAccuracy)
        #expect(record.preferences.sessionMinutes == nil)
    }

    @Test func preferenceEditsKeepLinesUniqueAndBlankGoalsOut() {
        var preferences = CoachPreferences.standard
        preferences.setAvoiding(lineID: "l1", isAvoiding: true)
        preferences.setAvoiding(lineID: "l1", isAvoiding: true)
        preferences.setAvoiding(lineID: "l2", isAvoiding: true)
        preferences.setAvoiding(lineID: "l2", isAvoiding: false)
        #expect(preferences.avoidLineIds == ["l1"])
        preferences.goalNote = "  \n "
        #expect(preferences.trimmed.goalNote == nil)
        preferences.goalNote = String(repeating: "a", count: CoachPreferences.goalNoteLimit + 1)
        #expect(preferences.isGoalNoteTooLong)
    }

    // MARK: Error mapping

    @Test func backendStatusesMapToTypedErrors() {
        func map(_ status: Int, _ body: String) -> CoachError {
            CoachError.response(operation: "Op", status: status, body: body, secrets: [])
        }
        #expect(map(401, #"{"error":"no","code":"unauthenticated"}"#) == .signInRequired)
        #expect(map(404, #"{"error":"no","code":"not_found"}"#) == .notFound(operation: "Op"))
        #expect(map(409, #"{"error":"stale","code":"version_conflict"}"#) == .versionConflict)
        #expect(map(400, #"{"error":"bad locale","code":"invalid_request"}"#) == .invalidRequest(operation: "Op", message: "bad locale"))
        #expect(map(502, #"{"error":"model unavailable","code":"provider_failed"}"#) == .providerFailed(operation: "Op", message: "model unavailable"))
        #expect(map(503, #"{"error":"x","code":"not_configured"}"#) == .serviceNotConfigured(operation: "Op"))
        #expect(map(409, #"{"error":"other","code":"something_else"}"#) == .requestFailed(operation: "Op", status: 409, body: "other"))
        #expect(map(500, "<html>gateway</html>") == .requestFailed(operation: "Op", status: 500, body: "<html>gateway</html>"))
    }

    @Test func errorBodiesNeverEchoTheRequestToken() {
        let error = CoachError.response(operation: "Op", status: 500, body: "bad header Bearer abc123 and abc123", secrets: ["Bearer abc123", "abc123"])
        guard case .requestFailed(_, _, let body) = error else {
            Issue.record("Expected a generic request failure")
            return
        }
        #expect(!body.contains("abc123"))
    }

    @Test func offlineIsToldApartFromOtherNetworkFailures() {
        #expect(CoachError.isOffline(URLError(.notConnectedToInternet)))
        #expect(!CoachError.isOffline(URLError(.timedOut)))
    }

    private struct NoToken: CoachAuthTokenProvider {
        func convexAuthToken() async throws -> String? { nil }
    }

    @Test func signedOutRequestsFailBeforeAnythingIsSent() async {
        let client = CoachBackendClient(baseURL: URL(string: "https://example.invalid")!, tokens: NoToken())
        await #expect(throws: CoachError.signInRequired) { try await client.preferences() }
        await #expect(throws: CoachError.signInRequired) { try await client.forgetMemory() }
    }

    // MARK: Exercise and context logic

    @Test func theCoachOnlyTalksAboutTheLineForTheLanguageBeingPractised() {
        let english = SpokenLanguage.all[0]
        let spanish = SpokenLanguage.all[3]
        let practice = CoachPracticeContext(lineID: "line_02", locale: english.identifier)
        #expect(CoachConversation.replyContext(language: english, practice: practice).lineId == "line_02")
        #expect(CoachConversation.replyContext(language: spanish, practice: practice).lineId == nil)
        #expect(CoachConversation.replyContext(language: spanish, practice: practice).locale == "es-ES")
        #expect(CoachConversation.replyContext(language: english, practice: nil).lineId == nil)
    }

    @Test func exerciseEvidenceNamesTheLineAndAttempts() {
        func exercise(attempts: [String], lineId: String?) -> NextExercise {
            NextExercise(
                kind: .retryLine, locale: "en-US", lineId: lineId, referenceVersion: 1, practiceText: nil,
                focus: .any, instruction: "Retry it.", reasonCode: "r",
                evidence: ExerciseEvidence(attemptIds: attempts, assessmentIds: [])
            )
        }
        #expect(exercise(attempts: ["t1"], lineId: "l1").evidenceSummary == "Based on your attempt t1 on line l1.")
        #expect(exercise(attempts: ["t1", "t2", "t3", "t4"], lineId: nil).evidenceSummary == "Based on your attempts t1, t2 and 2 more.")
        #expect(!exercise(attempts: [], lineId: nil).evidenceSummary.contains("Based on"))
    }

    @Test func memorySummaryCountsEachStateAndGatesForgetting() {
        #expect(CoachMemoryStatus(pending: 0, failed: 0, done: 0).storedCount == 0)
        let summary = CoachMemoryStatus(pending: 1, failed: 2, done: 5).summary
        #expect(summary.contains("5 remembered") && summary.contains("1 saving") && summary.contains("2 couldn't be saved"))
    }

    // MARK: Preferences and memory models

    private actor FakeTutorService: CoachTutorService {
        var stored: CoachPreferencesRecord
        var saveFailures: [CoachError]
        private(set) var savedVersions: [Int] = []
        private(set) var memory = CoachMemoryStatus(pending: 0, failed: 0, done: 4)
        private(set) var forgotten = false

        init(stored: CoachPreferencesRecord, saveFailures: [CoachError]) {
            self.stored = stored
            self.saveFailures = saveFailures
        }

        func replaceStored(_ record: CoachPreferencesRecord) { stored = record }
        func nextExercise(locale: String?) async throws -> NextExercise { throw CoachError.notFound(operation: "Exercise") }
        func preferences() async throws -> CoachPreferencesRecord { stored }

        func savePreferences(_ preferences: CoachPreferences, expectedVersion: Int) async throws -> CoachPreferencesRecord {
            savedVersions.append(expectedVersion)
            if !saveFailures.isEmpty { throw saveFailures.removeFirst() }
            stored = CoachPreferencesRecord(preferences: preferences, version: expectedVersion + 1)
            return stored
        }

        func memoryStatus() async throws -> CoachMemoryStatus { memory }

        func forgetMemory() async throws -> Int {
            forgotten = true
            let scheduled = memory.done
            memory = CoachMemoryStatus(pending: 0, failed: 0, done: 0)
            return scheduled
        }
    }

    @MainActor
    @Test func aVersionConflictReloadsTheServersPreferencesInsteadOfOverwriting() async {
        var serverPreferences = CoachPreferences.standard
        serverPreferences.focus = .fluency
        let service = FakeTutorService(stored: CoachPreferencesRecord(preferences: .standard, version: 1), saveFailures: [.versionConflict])
        let model = CoachPreferencesModel(service: service)
        await model.load()
        model.draft.challenge = .stretch
        await service.replaceStored(CoachPreferencesRecord(preferences: serverPreferences, version: 2))

        await model.save()
        #expect(model.phase == .editing)
        #expect(model.draft.focus == .fluency)
        #expect(model.draft.challenge == .standard)
        #expect(model.notice == CoachPreferencesModel.conflictNotice)

        model.draft.challenge = .stretch
        await model.save()
        #expect(await service.savedVersions == [1, 2])
        #expect(model.draft.challenge == .stretch)
        #expect(model.saveError == nil)
    }

    @MainActor
    @Test func aFailedSaveKeepsTheDraftAndSaysWhy() async {
        let service = FakeTutorService(stored: CoachPreferencesRecord(preferences: .standard, version: 0), saveFailures: [.offline(operation: "Saving your preferences")])
        let model = CoachPreferencesModel(service: service)
        await model.load()
        model.draft.challenge = .gentle
        await model.save()
        #expect(model.phase == .editing)
        #expect(model.draft.challenge == .gentle)
        #expect(model.saveError != nil)
    }

    @MainActor
    @Test func anOverlongGoalCannotBeSaved() async {
        let model = CoachPreferencesModel(service: FakeTutorService(stored: CoachPreferencesRecord(preferences: .standard, version: 0), saveFailures: []))
        await model.load()
        model.draft.goalNote = String(repeating: "a", count: CoachPreferences.goalNoteLimit + 1)
        #expect(!model.canSave)
    }

    @MainActor
    @Test func forgettingMemoryReloadsTheStatus() async {
        let service = FakeTutorService(stored: CoachPreferencesRecord(preferences: .standard, version: 0), saveFailures: [])
        let model = CoachMemoryModel(service: service)
        await model.load()
        await model.forget()
        #expect(await service.forgotten)
        guard case .loaded(let status) = model.status else {
            Issue.record("Expected the status to reload after forgetting")
            return
        }
        #expect(status.storedCount == 0)
        #expect(model.forgetError == nil)
    }
}
