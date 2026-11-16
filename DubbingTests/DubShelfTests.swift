import Foundation
import Testing
@testable import Dubbing

struct DubShelfTests {
    @Test func combinedDubsBelongToBothPerformersAndReplaceTheGuestsLocalCopy() throws {
        let room = completedRoom(id: "shared", owner: "demo", guest: "demo1")
        let unrelated = completedRoom(id: "unrelated", owner: "maya", guest: "theo")
        let combined = try SavedCoDub(room: room)
        let guestDub = savedDub(owner: "demo1", coDub: combined)
        let ownerDub = savedDub(owner: "demo", coDub: nil)
        let saved = [guestDub, ownerDub]
        let rooms = [room, unrelated]

        let guestShelf = try ShelfDub.merge(saved: saved, rooms: rooms, username: "demo1")
        #expect(guestShelf.count == 1)
        let entry = try #require(guestShelf.first)
        guard case .combined(let sharedRoom, let cast) = entry else {
            Issue.record("The shared result must replace the guest's local copy")
            return
        }
        #expect(sharedRoom.resultAssetId == room.resultAssetId)
        #expect(cast.ownerUsername == room.owner.username)
        #expect(cast.guestUsername == room.guest?.username)
        #expect(cast.ownerCharacterName == room.script.roleName(room.script.ownerCharacterId))
        #expect(cast.guestCharacterName == room.script.roleName(room.script.guestCharacterId))
        #expect(entry.linesDubbed == 2)
        #expect(entry.totalLines == 2)

        let ownerShelf = try ShelfDub.merge(saved: saved, rooms: rooms, username: "demo")
        #expect(Set(ownerShelf.map(\.id)) == [ownerDub.id.uuidString, room.id])
        #expect(try ShelfDub.merge(saved: saved, rooms: rooms, username: "jordan").isEmpty)
        #expect(try ShelfDub.merge(saved: saved, rooms: rooms, username: nil).isEmpty)
    }

    private func savedDub(owner: String, coDub: SavedCoDub?) -> SavedDub {
        let id = UUID()
        return SavedDub(id: id, sceneTitle: "Scene", characterName: "Character", linesDubbed: 1, totalLines: 1, sceneSeconds: 5, createdAt: .now, videoFileName: "\(id.uuidString).mp4", ownerUsername: owner, coDub: coDub)
    }

    private func completedRoom(id: String, owner: String, guest: String) -> CoDubRoom {
        let script = SocialScript(title: "Scene", duration: 5, locale: "en-US", speakers: [.init(id: 0, name: "First character"), .init(id: 1, name: "Second character")], lines: [.init(id: 0, speakerId: 0, text: "Hello", start: 0, end: 1), .init(id: 1, speakerId: 1, text: "Hi", start: 2, end: 3)], protectedSpans: [.init(start: 0, end: 1)], ownerCharacterId: 0, guestCharacterId: 1, ownerLinesRecorded: 1)
        return CoDubRoom(id: id, owner: .init(id: owner, username: owner), guest: .init(id: guest, username: guest), code: UUID().uuidString, script: script, status: .completed, joinOnly: false, sourceAssetId: "source", resultAssetId: "result", guestLinesRecorded: 1, approvedByMe: false, published: false, createdAt: 1_800_000_000_000)
    }
}
