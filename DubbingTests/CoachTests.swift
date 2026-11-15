import Foundation
import Testing
@testable import Dubbing

struct CoachTests {
    @Test func socketCommandsHaveTheLiteShape() throws {
        let eventID = UUID()
        func object(_ frame: String) throws -> [String: String] {
            try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: String])
        }
        let speak = try object(LiveAvatarSocketCommand.speak(audio: Data([1, 2, 3, 4]), eventID: eventID))
        #expect(speak == ["type": "agent.speak", "event_id": eventID.uuidString.lowercased(), "audio": Data([1, 2, 3, 4]).base64EncodedString()])
        #expect(try object(LiveAvatarSocketCommand.speakEnd(eventID: eventID))["type"] == "agent.speak_end")
        #expect(try object(LiveAvatarSocketCommand.interrupt(eventID: eventID))["audio"] == nil)
        #expect(try object(LiveAvatarSocketCommand.keepAlive(eventID: eventID))["type"] == "session.keep_alive")
    }

    @Test func decodesTheSocketEventsTheCoachFollowsAndSkipsTheRest() throws {
        func decode(_ json: String) throws -> LiveAvatarSocketEvent? {
            try LiveAvatarSocketEvent.decode(json)
        }
        #expect(try decode(#"{"type":"session.state_updated","state":"connected","event_id":"1","source_event_id":null}"#) == .connected)
        #expect(try decode(#"{"type":"session.state_updated","state":"disconnected"}"#) == .sessionDisconnected)
        #expect(try decode(#"{"type":"session.state_updated","state":"new"}"#) == nil)
        #expect(try decode(#"{"type":"agent.speak_started","source_event_id":"u"}"#) == .speakStarted)
        #expect(try decode(#"{"type":"agent.speak_ended","source_event_id":"u"}"#) == .speakEnded)
        #expect(try decode(#"{"type":"agent.speak_interrupted"}"#) == .speakInterrupted)
        #expect(try decode(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad audio","event_id":"e"}}"#) == .failed(type: "invalid_request_error", message: "bad audio"))
        #expect(try decode(#"{"type":"agent.audio_buffer_appended"}"#) == nil)
        #expect(try decode(#"{"type":"agent.state_updated","previous_state":"idle","new_state":"talking"}"#) == nil)
        #expect(throws: DecodingError.self) { try decode(#"{"state":"no type"}"#) }
    }

    @Test func replyAudioIsSplitIntoBoundedOneSecondChunks() throws {
        let chunks = try LiveAvatarAudio.chunks(of: Data(count: 120_000))
        #expect(chunks.map(\.count) == [48_000, 48_000, 24_000])
        #expect(throws: CoachError.self) { try LiveAvatarAudio.chunks(of: Data()) }
        #expect(throws: CoachError.self) { try LiveAvatarAudio.chunks(of: Data(count: 7)) }
        #expect(throws: CoachError.self) { try LiveAvatarAudio.chunks(of: Data(count: LiveAvatarAudio.maximumBytes + 2)) }
        #expect(try LiveAvatarAudio.chunks(of: Data(count: LiveAvatarAudio.maximumBytes)).count == 60)
    }

    @Test func chunksAreSentNoMoreThanTheLeadAheadOfPlayback() {
        let offsets = (0..<6).map { LiveAvatarAudio.sendOffset(ofChunk: $0) }
        #expect(offsets == [.seconds(0), .seconds(0), .seconds(0), .seconds(1), .seconds(2), .seconds(3)])
    }

    @Test func replyAudioMustBeThePcmFormatTheSocketAccepts() throws {
        let good = ReplyAudio(format: "pcm_s16le_24khz_mono", base64: Data([0, 1]).base64EncodedString(), aiGenerated: true)
        #expect(try good.pcm() == Data([0, 1]))
        #expect(throws: CoachError.self) { try ReplyAudio(format: "mp3", base64: "AAA=", aiGenerated: true).pcm() }
        #expect(throws: CoachError.self) { try ReplyAudio(format: "pcm_s16le_24khz_mono", base64: "not base64!", aiGenerated: true).pcm() }
    }

    @Test func aReplyWithAudioDecodesItsVoice() throws {
        let reply = try decodeReply(#"{"text":"Hi","audio":{"format":"pcm_s16le_24khz_mono","base64":"AAA=","aiGenerated":true}}"#)
        #expect(reply.audio?.aiGenerated == true)
        #expect(try decodeReply(#"{"text":"Hi"}"#).audio == nil)
    }

    // MARK: Avatar socket

    private actor FakeTransport: AvatarSocketTransport {
        private(set) var sent: [String] = []
        private(set) var isClosed = false
        private var pending: [String] = []
        private var waiter: CheckedContinuation<String, any Error>?

        func feed(_ frame: String) {
            guard let waiter else {
                pending.append(frame)
                return
            }
            self.waiter = nil
            waiter.resume(returning: frame)
        }

        func send(_ text: String) { sent.append(text) }

        func close() {
            isClosed = true
            waiter?.resume(throwing: CoachError.avatarDisconnected)
            waiter = nil
        }

        func receive() async throws -> String {
            if !pending.isEmpty { return pending.removeFirst() }
            if isClosed { throw CoachError.avatarDisconnected }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }

        func sentTypes() throws -> [String] {
            struct Frame: Decodable { let type: String }
            return try sent.map { try JSONDecoder().decode(Frame.self, from: Data($0.utf8)).type }
        }
    }

    private func connectedSocket(_ transport: FakeTransport) async -> LiveAvatarSocket {
        let socket = LiveAvatarSocket(transport: transport)
        await socket.start()
        await transport.feed(#"{"type":"session.state_updated","state":"connected"}"#)
        var events = socket.events.makeAsyncIterator()
        _ = await events.next()
        return socket
    }

    @Test func theSocketSendsNothingUntilTheServerSaysConnected() async {
        let transport = FakeTransport()
        let socket = LiveAvatarSocket(transport: transport)
        await socket.start()
        await #expect(throws: CoachError.avatarDisconnected) { try await socket.speak(Data(count: 4)) }
        #expect(await transport.sent.isEmpty)
        await socket.close()
    }

    @Test func aReplyIsSentAsChunksThenSealed() async throws {
        let transport = FakeTransport()
        let socket = await connectedSocket(transport)
        try await socket.speak(Data(count: 120_000))
        #expect(try await transport.sentTypes() == ["agent.speak", "agent.speak", "agent.speak", "agent.speak_end"])
        await socket.close()
    }

    @Test func interruptingStopsTheChunksStillWaitingToBeSent() async throws {
        let transport = FakeTransport()
        let socket = await connectedSocket(transport)
        let speaking = Task { try await socket.speak(Data(count: 6 * 48_000)) }
        while try await transport.sentTypes().count < 3 { await Task.yield() }
        try await socket.interrupt()
        try await speaking.value
        let types = try await transport.sentTypes()
        #expect(types.prefix(3).allSatisfy { $0 == "agent.speak" })
        #expect(types.contains("agent.interrupt"))
        #expect(!types.contains("agent.speak_end"))
        await socket.close()
    }

    @Test func closingInterruptsTheAvatarAndClosesTheTransport() async throws {
        let transport = FakeTransport()
        let socket = await connectedSocket(transport)
        await socket.close()
        #expect(try await transport.sentTypes() == ["agent.interrupt"])
        #expect(await transport.isClosed)
    }

    @Test func aSocketThatEndsOnItsOwnIsReported() async {
        let transport = FakeTransport()
        let socket = LiveAvatarSocket(transport: transport)
        await socket.start()
        await transport.close()
        var events = socket.events.makeAsyncIterator()
        guard case .closed = await events.next() else {
            Issue.record("Expected a closed event")
            return
        }
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
        #expect(reply.provenance == nil)
        #expect(reply.feedbackBasis == .none)
        #expect(reply.citedEvidenceIds.isEmpty)
        #expect(reply.exercise == nil)
    }

    @Test func aTutoringReplyDecodesItsBasisEvidenceAndExercise() throws {
        let reply = try decodeReply("""
        {"text":"Slow down on 'underestimate'.","source":"model",
         "provenance":{"provider":"openai","api":"responses","model":"gpt-6-luna","responseId":"resp_1"},
         "feedbackBasis":"script_agreement","citedEvidenceIds":["take_003"],"unrelated":true,
         "exercise":{"kind":"drill_word","locale":"en-US","lineId":"line_02","referenceVersion":1,
           "practiceText":"underestimate","focus":"word_accuracy","instruction":"Say it slowly.",
           "reasonCode":"recurring_word","basis":"script_agreement",
           "evidence":{"attemptIds":["take_003"],"assessmentIds":["a_1"]}}}
        """)
        #expect(reply.source == .model)
        #expect(reply.provenance?.summary == "openai/gpt-6-luna")
        #expect(reply.exercise?.basis == .scriptAgreement)
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
        preferences.memory = .off
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        #expect(Set(json.keys) == ["focus", "challenge", "avoidLineIds", "memory"])
        #expect(json["memory"] as? String == "off")
        let record = try JSONDecoder().decode(CoachPreferencesRecord.self, from: Data(#"{"preferences":{"focus":"word_accuracy","challenge":"stretch","avoidLineIds":["l1"],"memory":"on","goalNote":"Order food"},"version":3}"#.utf8))
        #expect(record.version == 3)
        #expect(record.preferences.focus == .wordAccuracy)
        #expect(record.preferences.memory == .on)
    }

    @Test func preferenceEditsKeepLinesUniqueAndBlankGoalsOut() {
        var preferences = CoachPreferences.standard
        preferences.setAvoiding(lineID: "l1", isAvoiding: true)
        preferences.setAvoiding(lineID: "l1", isAvoiding: true)
        preferences.setAvoiding(lineID: "l2", isAvoiding: true)
        preferences.setAvoiding(lineID: "l2", isAvoiding: false)
        #expect(preferences.avoidLineIds == ["l1"])
        for index in 0..<(CoachPreferences.avoidLineLimit + 5) { preferences.setAvoiding(lineID: "extra\(index)", isAvoiding: true) }
        #expect(preferences.avoidLineIds.count == CoachPreferences.avoidLineLimit)
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
        #expect(map(504, #"{"error":"slow","code":"provider_timeout"}"#) == .providerTimeout(operation: "Op"))
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
        let client = CoachBackendClient(baseURL: URL(string: "https://example.invalid")!, tokens: NoToken(), qaFault: nil)
        await #expect(throws: CoachError.signInRequired) { try await client.preferences() }
        await #expect(throws: CoachError.signInRequired) { try await client.forgetMemory() }
    }

    // MARK: Exercise and context logic

    @Test func theBackendCodeAndRetryabilityFollowTheError() {
        #expect(CoachError.providerTimeout(operation: "Op").backendCode == "provider_timeout")
        #expect(CoachError.serviceNotConfigured(operation: "Op").backendCode == "not_configured")
        #expect(CoachError.providerFailed(operation: "Op", message: "m").backendCode == "provider_failed")
        #expect(CoachError.signInRequired.backendCode == "unauthenticated")
        #expect(CoachError.noSpeechHeard.backendCode == nil)
        #expect(CoachError.providerTimeout(operation: "Op").isRetryable)
        #expect(CoachError.serviceNotConfigured(operation: "Op").isRetryable)
        #expect(!CoachError.invalidRequest(operation: "Op", message: "m").isRetryable)
        #expect(!CoachError.signInRequired.isRetryable)
    }

    @Test func qaSwitchesParseOnlyKnownFaults() {
        #expect(CoachQAOptions.parse(uiTest: true, fault: "provider_timeout") == CoachQAOptions(isUITest: true, fault: .providerTimeout))
        #expect(CoachQAOptions.parse(uiTest: false, fault: "missing_key").fault == .missingKey)
        #expect(CoachQAOptions.parse(uiTest: true, fault: "provider_erorr").fault == nil)
        #expect(CoachQAOptions.parse(uiTest: true, fault: nil).fault == nil)
        #expect(CoachQAFault.header == "X-QA-Fault")
    }

    // MARK: Progress

    private func decodeSeries(_ json: String) throws -> ProgressSeries {
        try JSONDecoder().decode(ProgressSeries.self, from: Data(json.utf8))
    }

    @Test func theFullDocumentedSeriesDecodes() throws {
        let series = try decodeSeries(CoachFixtures.acousticSeries)
        #expect(series.locale == "en-US")
        #expect(series.evaluator.measurement == .acoustic)
        #expect(series.evaluator.modelVersion == nil)
        #expect(series.pronunciationBasis == .acoustic)
        #expect(series.volume.attempts == 5 && series.volume.scorableAttempts == 4 && series.volume.practiceDays == 2)
        #expect(series.daily.map(\.date) == ["2026-11-10", "2026-11-12"])
        #expect(series.daily[1].firstScorable.languageOverall == MetricValue(value: 91.5, samples: 2))
        #expect(series.daily[0].bestAttempt.fluency?.value == 80)
        #expect(series.skills.first { $0.metric == "fluency" }?.direction == .improving)
        #expect(series.skills.first { $0.metric == "languageOverall" }?.change == 4.5)
        #expect(series.lines.map(\.lineId) == ["scene_001_line_02", "scene_001_line_05"])
        #expect(series.lines[0].latestScores?.pronunciation == 84)
        #expect(series.repeatedLines[0].latest.assessmentId == "as4b")
        #expect(series.words[0].word == "underestimate")
        #expect(series.words[0].pronunciationIssueAssessmentIds == ["as1", "as2", "as4b"])
        #expect(series.guidance.focusAreas[0].word == "underestimate")
        #expect(series.guidance.retryLines[0].practiceWords == ["underestimate"])
        #expect(series.guidance.newLines.isEmpty)
    }

    @Test func aTranscriptOnlySeriesNeverShowsPronunciationOrFluency() throws {
        let acoustic = try decodeSeries(CoachFixtures.acousticSeries)
        for metric in ScoreMetric.allCases { #expect(acoustic.canShow(metric)) }
        #expect(acoustic.shownPronunciationScore(for: acoustic.words[0]) == 61)

        let transcriptOnly = try decodeSeries(
            CoachFixtures.acousticSeries
                .replacing(#""measurement": "acoustic""#, with: #""measurement": "transcript_only""#)
                .replacing(#""pronunciationBasis": "acoustic""#, with: #""pronunciationBasis": "script_agreement""#)
        )
        #expect(!transcriptOnly.canShow(.pronunciation))
        #expect(!transcriptOnly.canShow(.fluency))
        #expect(transcriptOnly.canShow(.wordAccuracy) && transcriptOnly.canShow(.timingFit))
        #expect(transcriptOnly.shownPronunciationScore(for: transcriptOnly.words[0]) == nil)

        let withUnavailable = try decodeSeries(
            CoachFixtures.acousticSeries.replacing(#""unavailableMetrics": []"#, with: #""unavailableMetrics": [{"metric":"timingFit","reason":"insufficient_evidence"}]"#)
        )
        #expect(!withUnavailable.canShow(.timingFit))
    }

    @Test func aMissingMeasurementIsTreatedAsTranscriptOnly() throws {
        let series = try decodeSeries(CoachFixtures.acousticSeries.replacing(#""measurement": "acoustic""#, with: #""measurement": "mystery""#))
        #expect(series.evaluator.measurement == .transcriptOnly)
        #expect(!series.canShow(.pronunciation))
    }

    @Test func memoryItemsDecodeWithoutScoresAndToleratesNewKinds() throws {
        let json = #"{"items":[{"docId":"attempt-1","kind":"attempt_note","text":"Struggled with 'underestimate'.","sourceIds":["a1","as1"],"state":"done"},{"docId":"x","kind":"future_kind","text":"t","sourceIds":[],"state":"pending"}]}"#
        struct Response: Decodable { let items: [MemoryItem] }
        let items = try JSONDecoder().decode(Response.self, from: Data(json.utf8)).items
        #expect(items.map(\.kind) == [.attemptNote, .other])
        #expect(items[0].state == .done && items[1].state == .pending)
        #expect(items[0].sourceIds == ["a1", "as1"])
    }

    @Test func exerciseEvidenceNamesTheLineAndAttempts() {
        func exercise(attempts: [String], lineId: String?) -> NextExercise {
            NextExercise(
                kind: .retryLine, locale: "en-US", lineId: lineId, referenceVersion: 1, practiceText: nil,
                focus: .any, instruction: "Retry it.", reasonCode: "r", basis: .none,
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

        func memoryItems() async throws -> [MemoryItem] {
            struct Response: Decodable { let items: [MemoryItem] }
            let items = (0..<memory.done).map { #"{"docId":"doc\#($0)","kind":"attempt_note","text":"Note \#($0)","sourceIds":[],"state":"done"}"# }
            return try JSONDecoder().decode(Response.self, from: Data(#"{"items":[\#(items.joined(separator: ","))]}"#.utf8)).items
        }

        func forgetMemory() async throws -> Int {
            forgotten = true
            let scheduled = memory.done
            memory = CoachMemoryStatus(pending: 0, failed: 0, done: 0)
            stored = CoachPreferencesRecord(preferences: { var off = stored.preferences; off.memory = .off; return off }(), version: stored.version + 1)
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
        guard case .loaded(let before) = model.snapshot else {
            Issue.record("Expected the memory to load")
            return
        }
        #expect(before.items.count == 4)
        await model.forget()
        #expect(await service.forgotten)
        guard case .loaded(let snapshot) = model.snapshot else {
            Issue.record("Expected the memory to reload after forgetting")
            return
        }
        #expect(snapshot.status.storedCount == 0)
        #expect(snapshot.items.isEmpty)
        #expect(model.forgetError == nil)
    }

    @MainActor
    @Test func forgettingMemoryPicksUpTheServersMemoryOffWithoutLosingOtherEdits() async throws {
        let service = FakeTutorService(stored: CoachPreferencesRecord(preferences: .standard, version: 4), saveFailures: [])
        let preferences = CoachPreferencesModel(service: service)
        await preferences.load()
        preferences.draft.challenge = .stretch
        _ = try await service.forgetMemory()
        await preferences.syncMemoryMode()
        #expect(preferences.draft.memory == .off)
        #expect(preferences.draft.challenge == .stretch)
        await preferences.save()
        #expect(await service.savedVersions == [5])
        #expect(preferences.saveError == nil)
    }
}
