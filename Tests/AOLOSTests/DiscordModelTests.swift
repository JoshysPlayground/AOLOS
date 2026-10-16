import XCTest
@testable import AOLOS

final class DiscordModelTests: XCTestCase {
    func testBuddyParsing() throws {
        let buddy = try XCTUnwrap(Buddy(json: [
            "id": "42", "name": "SurfinJerry", "username": "jerry", "status": "online",
            "desktop": "", "mobile": "online", "web": "",
            "avatar": "https://cdn.discordapp.com/avatars/42/abc.png?size=64", "activity": "Playing Snake",
        ]))
        XCTAssertEqual(buddy.name, "SurfinJerry")
        XCTAssertEqual(buddy.presence, .online)
        XCTAssertTrue(buddy.mobileOnly)
        XCTAssertEqual(buddy.avatarURL?.host, "cdn.discordapp.com")
        XCTAssertNil(Buddy(json: ["name": "no id"]))
    }

    func testDesktopAndMobileIsNotMobileOnly() throws {
        let buddy = try XCTUnwrap(Buddy(json: ["id": "1", "status": "idle", "desktop": "idle", "mobile": "online"]))
        XCTAssertFalse(buddy.mobileOnly)
    }

    func testUnknownAndInvisibleStatusesAreOffline() throws {
        XCTAssertEqual(try XCTUnwrap(Buddy(json: ["id": "1", "status": "invisible"])).presence, .offline)
        XCTAssertEqual(try XCTUnwrap(Buddy(json: ["id": "1"])).presence, .offline)
    }

    func testPresenceChanges() {
        XCTAssertEqual(BuddyChange.between(.offline, .online), .signedOn)
        XCTAssertEqual(BuddyChange.between(.offline, .idle), .signedOn)
        XCTAssertEqual(BuddyChange.between(.online, .offline), .signedOff)
        XCTAssertEqual(BuddyChange.between(.idle, .offline), .signedOff)
        XCTAssertEqual(BuddyChange.between(.online, .idle), .away)
        XCTAssertEqual(BuddyChange.between(.dnd, .idle), .away)
        XCTAssertEqual(BuddyChange.between(.idle, .online), .back)
        XCTAssertNil(BuddyChange.between(.online, .dnd))
        XCTAssertNil(BuddyChange.between(.online, .online))
        XCTAssertNil(BuddyChange.between(.offline, .offline))
    }

    func testChangeSounds() {
        XCTAssertEqual(BuddyChange.signedOn.sound, .buddyIn)
        XCTAssertEqual(BuddyChange.signedOff.sound, .buddyOut)
        XCTAssertEqual(BuddyChange.away.sound, .doorClose)
        XCTAssertEqual(BuddyChange.back.sound, .doorOpen)
    }

    func testSortPutsOnlineFirstThenName() {
        let sorted = BuddySort.sorted([
            Buddy(id: "1", name: "zed", presence: .offline),
            Buddy(id: "2", name: "Bob", presence: .idle),
            Buddy(id: "3", name: "alice", presence: .online),
        ])
        XCTAssertEqual(sorted.map(\.id), ["3", "2", "1"])
    }

    func testDirectMessageParsing() throws {
        let message = try XCTUnwrap(DirectMessage(json: ["id": "9", "authorID": "42", "text": "hi", "time": 1_700_000_000_000]))
        XCTAssertEqual(message.date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(DirectMessage(json: ["text": "no id"]))
    }

    func testDiscordHost() {
        XCTAssertTrue(DiscordBridge.isDiscordHost("discord.com"))
        XCTAssertTrue(DiscordBridge.isDiscordHost("ptb.discord.com"))
        XCTAssertFalse(DiscordBridge.isDiscordHost("notdiscord.com"))
        XCTAssertFalse(DiscordBridge.isDiscordHost(nil))
    }
}

final class RecentBuddiesTests: XCTestCase {
    func testRecentSkipsHiddenAndDuplicatesAndCaps() {
        var recent = [Buddy(id: "h", name: "hidden", presence: .online), Buddy(id: "a", name: "a", presence: .offline),
                      Buddy(id: "a", name: "a", presence: .offline)]
        recent += (0..<20).map { Buddy(id: "x\($0)", name: "x", presence: .online) }
        let picked = RecentBuddies.pick(recent, hidden: ["h"])
        XCTAssertEqual(picked.first?.id, "a")
        XCTAssertEqual(picked.count, RecentBuddies.limit)
        XCTAssertEqual(Set(picked.map(\.id)).count, picked.count)
    }
}

final class MessageMediaTests: XCTestCase {
    func testMessageMediaParsing() throws {
        let message = try XCTUnwrap(DirectMessage(json: [
            "id": "1", "authorID": "2", "text": "look", "time": 0,
            "images": [["url": "https://media.discordapp.net/a.png", "name": "a.png", "width": 1000, "height": 500]],
            "files": [["url": "https://cdn.discordapp.com/b.zip", "name": "b.zip"], ["url": "javascript:alert(1)"]],
        ]))
        XCTAssertEqual(message.images.first?.size, CGSize(width: 1000, height: 500))
        XCTAssertEqual(message.files.map(\.name), ["b.zip"])
    }

    func testDisplaySizeFitsWithoutUpscaling() {
        XCTAssertEqual(MessageMedia.displaySize(for: CGSize(width: 1000, height: 500)), CGSize(width: 260, height: 130))
        XCTAssertEqual(MessageMedia.displaySize(for: CGSize(width: 100, height: 400)), CGSize(width: 55, height: 220))
        XCTAssertEqual(MessageMedia.displaySize(for: CGSize(width: 50, height: 40)), CGSize(width: 50, height: 40))
        XCTAssertEqual(MessageMedia.displaySize(for: .zero), CGSize(width: 160, height: 120))
    }
}

final class GroupChatTests: XCTestCase {
    func testGroupChatParsing() throws {
        let chat = try XCTUnwrap(GroupChat(json: [
            "id": "77", "name": "1.0 enjoyers",
            "members": [["id": "1", "name": "a", "status": "online"], ["id": "2", "name": "b", "status": "offline"]],
        ]))
        XCTAssertEqual(chat.members.count, 2)
        XCTAssertEqual(chat.onlineCount, 1)
        XCTAssertNil(GroupChat(json: ["name": "no id"]))
    }

    func testChatTargetScriptValue() {
        XCTAssertEqual(ChatTarget.user("5").scriptValue as? String, "5")
        XCTAssertEqual((ChatTarget.channel("9").scriptValue as? [String: String])?["channelId"], "9")
        XCTAssertEqual(ChatTarget.channel("9").id, "9")
    }

    func testAuthorNameParsing() throws {
        let message = try XCTUnwrap(DirectMessage(json: ["id": "1", "authorID": "2", "authorName": "Aesh", "text": "hi"]))
        XCTAssertEqual(message.authorName, "Aesh")
    }
}

final class ChatRoomTests: XCTestCase {
    func testServerAndRoomParsing() throws {
        let server = try XCTUnwrap(ChatServer(json: ["id": "1", "name": "CEXI", "icon": "https://cdn.discordapp.com/icons/1/a.png"]))
        XCTAssertEqual(server.iconURL?.host, "cdn.discordapp.com")
        let room = try XCTUnwrap(ChatRoom(json: ["id": "2", "name": "general", "category": "Text", "unread": true]))
        XCTAssertTrue(room.unread)
        XCTAssertEqual(room.category, "Text")
        XCTAssertNil(ChatRoom(json: ["name": "no id"]))
    }
}

final class ReplyReactionTests: XCTestCase {
    func testReplyAndReactionParsing() throws {
        let message = try XCTUnwrap(DirectMessage(json: [
            "id": "5", "channelID": "c1", "authorID": "2", "text": "yes",
            "reply": ["id": "4", "authorName": "Ricon", "text": "Right?"],
            "reactions": [["name": "\u{1F44D}", "count": 3, "me": true], ["name": ":kekw:", "count": 1]],
        ]))
        XCTAssertEqual(message.channelID, "c1")
        XCTAssertEqual(message.reply?.authorName, "Ricon")
        XCTAssertEqual(message.reactions.map(\.count), [3, 1])
        XCTAssertTrue(message.reactions[0].mine)
        XCTAssertNil(try XCTUnwrap(DirectMessage(json: ["id": "6"])).reply)
    }

    func testVoiceRoomParsing() throws {
        let room = try XCTUnwrap(ChatRoom(json: ["id": "9", "name": "General", "voice": true, "people": ["Aesh"], "joined": true]))
        XCTAssertTrue(room.voice)
        XCTAssertEqual(room.people, ["Aesh"])
        XCTAssertTrue(room.joined)
    }
}
