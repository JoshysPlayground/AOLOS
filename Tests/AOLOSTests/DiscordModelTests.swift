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
