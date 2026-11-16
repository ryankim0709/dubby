import Foundation

nonisolated struct SavedCoDub: Codable, Hashable, Sendable {
    let roomID: String
    let ownerUsername: String
    let ownerCharacterName: String
    let guestUsername: String
    let guestCharacterName: String

    init(room: CoDubRoom) throws {
        guard let guest = room.guest, !room.joinOnly,
              room.script.speakers.contains(where: { $0.id == room.script.ownerCharacterId }),
              room.script.speakers.contains(where: { $0.id == room.script.guestCharacterId }) else {
            throw SocialError.invalidResponse("The co-dub is missing one of its performers or character roles.")
        }
        roomID = room.id
        ownerUsername = room.owner.username
        ownerCharacterName = room.script.roleName(room.script.ownerCharacterId)
        guestUsername = guest.username
        guestCharacterName = room.script.roleName(room.script.guestCharacterId)
    }

    var cast: String {
        "@\(ownerUsername) as \(ownerCharacterName)\n@\(guestUsername) as \(guestCharacterName)"
    }
}

nonisolated enum ShelfDub: Identifiable, Sendable {
    case saved(SavedDub)
    case combined(CoDubRoom, SavedCoDub)

    var id: String {
        switch self {
        case .saved(let dub): dub.id.uuidString
        case .combined(let room, _): room.id
        }
    }

    var title: String {
        switch self {
        case .saved(let dub): dub.sceneTitle
        case .combined(let room, _): room.script.title
        }
    }

    var cast: String {
        switch self {
        case .saved(let dub): dub.coDub?.cast ?? "as \(dub.characterName)"
        case .combined(_, let coDub): coDub.cast
        }
    }

    var createdAt: Date {
        switch self {
        case .saved(let dub): dub.createdAt
        case .combined(let room, _): Date(timeIntervalSince1970: room.createdAt / 1000)
        }
    }

    var isCoDub: Bool {
        switch self {
        case .saved(let dub): dub.coDub != nil
        case .combined: true
        }
    }

    var isPublished: Bool {
        switch self {
        case .saved: false
        case .combined(let room, _): room.published
        }
    }

    var linesDubbed: Int {
        switch self {
        case .saved(let dub): dub.linesDubbed
        case .combined(let room, _): room.script.ownerLinesRecorded + (room.guestLinesRecorded ?? 0)
        }
    }

    var totalLines: Int {
        switch self {
        case .saved(let dub): dub.totalLines
        case .combined(let room, _): room.script.lines.filter { $0.speakerId == room.script.ownerCharacterId || $0.speakerId == room.script.guestCharacterId }.count
        }
    }

    static func merge(saved: [SavedDub], rooms: [CoDubRoom], username: String?) throws -> [ShelfDub] {
        let completed = rooms.filter { room in
            guard let username else { return false }
            return room.status == .completed && !room.joinOnly &&
                (room.owner.username == username || room.guest?.username == username)
        }
        let combined: [ShelfDub] = try completed.map { room in
            guard room.resultAssetId != nil, room.guestLinesRecorded != nil else {
                throw SocialError.invalidResponse("The completed co-dub is missing its combined video or recorded line count.")
            }
            return .combined(room, try SavedCoDub(room: room))
        }
        let completedIDs = Set(completed.map(\.id))
        let local: [ShelfDub] = saved.filter { dub in
            dub.ownerUsername == username && !completedIDs.contains(dub.coDub?.roomID ?? "")
        }.map { .saved($0) }
        return (local + combined).sorted { $0.createdAt > $1.createdAt }
    }
}
