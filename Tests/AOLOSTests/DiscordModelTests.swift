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
