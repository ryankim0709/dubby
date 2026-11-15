import Foundation

nonisolated struct SocialPerson: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let username: String
}

nonisolated struct SocialFriendRequest: Decodable, Identifiable, Sendable {
    let id: String
    let person: SocialPerson
    let incoming: Bool
}

nonisolated struct SocialScript: Codable, Hashable, Sendable {
    struct Role: Codable, Hashable, Identifiable, Sendable {
        let id: Int
        let name: String
    }
    struct Line: Codable, Hashable, Identifiable, Sendable {
        let id: Int
        let speakerId: Int
        let text: String
        let start: Double
        let end: Double
    }
    let title: String
    let duration: Double
    let locale: String
    let speakers: [Role]
    let lines: [Line]
    let protectedSpans: [TimeSpan]
    let ownerCharacterId: Int
    let guestCharacterId: Int
    let ownerLinesRecorded: Int

    func roleName(_ id: Int) -> String {
        speakers.first { $0.id == id }?.name ?? "Character"
    }

    func setup(video: URL, characterId: Int, protectedSpans: [TimeSpan]) throws -> DubSetup {
        guard duration.isFinite, (2...30).contains(duration), speakers.contains(where: { $0.id == characterId }),
              SpokenLanguage.all.contains(where: { $0.identifier == locale }),
              Set(speakers.map(\.id)).count == speakers.count, speakers.allSatisfy({ $0.id >= 0 && !$0.name.isEmpty }),
              Set(lines.map(\.id)).count == lines.count, !lines.isEmpty,
              lines.allSatisfy({ line in line.id >= 0 && speakers.contains(where: { $0.id == line.speakerId }) && line.start.isFinite && line.end.isFinite && line.start >= 0 && line.start < line.end && line.end <= duration }),
              protectedSpans.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start < $0.end && $0.end <= duration }) else {
            throw SocialError.invalidResponse("The invitation has an invalid script, role, locale, or timing.")
        }
        let clip = ImportedClip(url: video, title: title, durationSeconds: duration, origin: .bundled, workingDirectory: video.deletingLastPathComponent())
        let script = Script(
            lines: lines.map { ScriptLine(id: $0.id, text: $0.text, start: $0.start, end: $0.end, speakerID: $0.speakerId, envelope: [], reference: nil) },
            speakers: speakers.map { Speaker(id: $0.id, name: $0.name) }
        )
        // Social takes use the supplied timed script; no new transcription or provider call is needed.
        return DubSetup(clip: clip, section: ClipSection(start: 0, end: duration), script: script, characterID: characterId, locale: locale, protectedAudioSpans: protectedSpans)
    }
}

nonisolated enum CoDubStatus: String, Decodable, Sendable {
    case invited, accepted, completed, declined, cancelled

    var title: String {
        switch self {
        case .invited: "Invitation open"
        case .accepted: "In the studio"
        case .completed: "That's a wrap"
        case .declined: "Invitation declined"
        case .cancelled: "Invitation cancelled"
        }
    }
}

nonisolated struct CoDubRoom: Decodable, Identifiable, Sendable {
    let id: String
    let owner: SocialPerson
    let guest: SocialPerson?
    let code: String
    let script: SocialScript
    let status: CoDubStatus
    let sourceAssetId: String
    let resultAssetId: String?
    let guestLinesRecorded: Int?
    let approvedByMe: Bool
    let published: Bool
    let createdAt: Double
}

nonisolated struct SocialPost: Decodable, Identifiable, Sendable {
    let id: String
    let owner: SocialPerson
    let guest: SocialPerson?
    let title: String
    let characterName: String
    let guestCharacterName: String?
    let linesRecorded: Int
    let guestLinesRecorded: Int?
    let assetId: String
    let coDubId: String?
    let createdAt: Double
}

nonisolated struct SocialSnapshot: Decodable, Sendable {
    let me: SocialPerson
    let friends: [SocialPerson]
    let requests: [SocialFriendRequest]
    let rooms: [CoDubRoom]
    let posts: [SocialPost]
}

nonisolated enum SocialError: LocalizedError, Sendable {
    case unavailable
    case signInRequired
    case invalidResponse(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Social sharing isn't configured in this build."
        case .signInRequired: "Sign in to find friends and share dubs."
        case .invalidResponse(let reason), .rejected(let reason): reason
        }
    }
}

/// An unguessable invitation code grants one signed-in learner the unclaimed role, never anonymous media access.
nonisolated enum CoDubLink {
    static func url(code: String) throws -> URL {
        guard UUID(uuidString: code) != nil, let url = URL(string: "dubby://invite/\(code.lowercased())") else {
            throw SocialError.invalidResponse("The invitation code isn't valid.")
        }
        return url
    }

    static func code(from text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: value) != nil { return value.lowercased() }
        guard let url = URL(string: value), url.scheme == "dubby", url.host() == "invite", url.pathComponents.count == 2,
              UUID(uuidString: url.lastPathComponent) != nil else {
            throw SocialError.rejected("Paste a Dubby invitation link or its complete invitation code.")
        }
        return url.lastPathComponent.lowercased()
    }
}

struct SocialDubSource: Identifiable {
    let video: URL
    let setup: DubSetup
    let takes: [Int: RecordedTake]
    var id: URL { video }

    var isRoleComplete: Bool {
        let lines = setup.script.lines(spokenBy: setup.characterID)
        return !lines.isEmpty && lines.allSatisfy { takes[$0.id] != nil }
    }

    func invitationScript(guestCharacterId: Int) throws -> SocialScript {
        let ownerLines = setup.script.lines(spokenBy: setup.characterID)
        guard isRoleComplete else {
            throw SocialError.rejected("Keep every line of your character before inviting a friend.")
        }
        let placements = ScriptBuilder.takePlacements(lines: setup.script.lines, takes: takes, sectionDuration: setup.section.duration, grace: DubTiming.lineGrace)
        let protected = placements.map { TimeSpan(start: $0.start, end: $0.start + $0.duration) }
        let guestLines = setup.script.lines(spokenBy: guestCharacterId)
        guard guestCharacterId != setup.characterID, !guestLines.isEmpty,
              guestLines.allSatisfy({ line in !protected.contains { $0.start < line.end && $0.end > line.start } }) else {
            throw SocialError.rejected("This role overlaps your kept performance. Choose another role or scene.")
        }
        return SocialScript(title: setup.clip.title, duration: setup.section.duration, locale: setup.locale, speakers: setup.script.speakers.map { .init(id: $0.id, name: $0.name) }, lines: setup.script.lines.map { .init(id: $0.id, speakerId: $0.speakerID, text: $0.text, start: $0.start, end: $0.end) }, protectedSpans: protected, ownerCharacterId: setup.characterID, guestCharacterId: guestCharacterId, ownerLinesRecorded: ownerLines.count)
    }
}

struct SocialDubLaunch {
    let setup: DubSetup
    /// Nil for a rematch's first role; its result starts a fresh invitation.
    let completionRoom: CoDubRoom?
}

struct SocialRoomSelection: Identifiable { let id: String }
