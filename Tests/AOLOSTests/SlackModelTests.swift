import XCTest
@testable import AOLOS

final class SlackModelTests: XCTestCase {
    private let alice = SlackUser(json: [
        "id": "U1", "name": "alice",
        "profile": ["display_name": "Alice", "image_48": "https://avatars.slack-edge.com/a.png",
                    "status_emoji": ":palm_tree:", "status_text": "On vacation"],
    ])!

    func testIDsCarryThePrefix() {
        XCTAssertEqual(SlackID.wrap("U1"), "slack:U1")
        XCTAssertEqual(SlackID.raw("slack:C9"), "C9")
        XCTAssertEqual(SlackID.raw("1234"), "1234")
        XCTAssertTrue(SlackID.owns("slack:D1"))
        XCTAssertFalse(SlackID.owns("80351110224678912"))
        XCTAssertEqual(ChatServiceKind(id: "slack:U1"), .slack)
        XCTAssertEqual(ChatServiceKind(id: "42"), .discord)
    }

    func testUserBecomesBuddy() {
        let buddy = alice.buddy(presence: .online)
        XCTAssertEqual(buddy.id, "slack:U1")
        XCTAssertEqual(buddy.name, "Alice")
        XCTAssertEqual(buddy.activity, "\u{1F334} On vacation")
        XCTAssertTrue(alice.isPerson)
        XCTAssertFalse(SlackUser(json: ["id": "USLACKBOT", "name": "slackbot"])!.isPerson)
        XCTAssertFalse(SlackUser(json: ["id": "B1", "name": "bot", "is_bot": true])!.isPerson)
    }

    func testRealNameWhenNoDisplayName() {
        let user = SlackUser(json: ["id": "U2", "name": "bob", "profile": ["display_name": "", "real_name": "Bob Smith"]])!
        XCTAssertEqual(user.name, "Bob Smith")
    }

    func testPresence() {
        XCTAssertEqual(SlackPresence.parse("active"), .online)
        XCTAssertEqual(SlackPresence.parse("away"), .offline)
        XCTAssertEqual(SlackPresence.parse(nil), .offline)
    }

    func testGroupNameHandles() {
        XCTAssertEqual(SlackGroupName.handles("mpdm-alice--bob--carol-1"), ["alice", "bob", "carol"])
        XCTAssertEqual(SlackGroupName.handles("mpdm-a.b--c_d-12"), ["a.b", "c_d"])
        XCTAssertEqual(SlackGroupName.handles("general"), [])
    }

    func testPlainTextResolvesMarkup() {
        let names = ["U1": "Alice"]
        let text = "hey <@U1>, see <#C1|general> &amp; <https://example.com|the doc> or <https://a.b> <!here> :tada:"
        XCTAssertEqual(SlackText.plain(text) { names[$0] },
                       "hey @Alice, see #general & the doc (https://example.com) or https://a.b @here \u{1F389}")
        XCTAssertEqual(SlackText.plain("<mailto:a@b.com|a@b.com> 1 &lt; 2") { _ in nil }, "a@b.com 1 < 2")
        XCTAssertEqual(SlackText.plain("<@U9|zed> :not_an_emoji:") { _ in nil }, "@zed :not_an_emoji:")
    }

    func testOutgoingEscapesAndConvertsMarkers() {
        XCTAssertEqual(SlackText.outgoing("a < b & **bold** *it* ~~gone~~ __u__"), "a &lt; b &amp; *bold* _it_ ~gone~ u")
    }

    func testMentions() {
        XCTAssertTrue(SlackText.mentions("hi <@U1>", userID: "U1"))
        XCTAssertTrue(SlackText.mentions("hi <@U1|alice>", userID: "U1"))
        XCTAssertFalse(SlackText.mentions("hi <@U12>", userID: "U1"))
    }

    func testMessageParsing() throws {
        let json: [String: Any] = [
            "ts": "1700000000.000100", "user": "U1", "text": "look", "thread_ts": "1699999999.000001",
            "parent_user_id": "U1",
            "reactions": [["name": "+1", "count": 2, "users": ["U1", "U2"]]],
            "files": [
                ["name": "pic.png", "mimetype": "image/png", "thumb_720": "https://files.slack.com/t.png",
                 "original_w": 800, "original_h": 600],
                ["name": "doc.pdf", "mimetype": "application/pdf", "permalink": "https://x.slack.com/files/U1/F1/doc.pdf"],
            ],
        ]
        let message = try XCTUnwrap(SlackMessage.parse(json, channel: "D1", me: "U2") { $0 == "U1" ? self.alice : nil })
        XCTAssertEqual(message.id, "1700000000.000100")
        XCTAssertEqual(message.authorID, "slack:U1")
        XCTAssertEqual(message.authorName, "Alice")
        XCTAssertEqual(message.channelID, "slack:D1")
        XCTAssertEqual(message.date.timeIntervalSince1970, 1_700_000_000.0001, accuracy: 0.001)
        XCTAssertEqual(message.reply?.id, "1699999999.000001")
        XCTAssertEqual(message.reactions, [MessageReaction(json: ["name": "\u{1F44D}", "count": 2, "me": true])!])
        XCTAssertEqual(message.images.first?.size, CGSize(width: 800, height: 600))
        XCTAssertEqual(message.files.first?.name, "doc.pdf")
    }

    func testJoinsAndEditsAreSkipped() {
        let join: [String: Any] = ["ts": "1.0", "user": "U1", "subtype": "channel_join", "text": "joined"]
        XCTAssertNil(SlackMessage.parse(join, channel: "C1", me: "U2") { _ in nil })
        let share: [String: Any] = ["ts": "1.0", "user": "U1", "subtype": "file_share", "text": ""]
        XCTAssertNotNil(SlackMessage.parse(share, channel: "C1", me: "U2") { _ in nil })
    }

    func testFormBodyEncodesJSONValues() {
        let body = SlackAPI.formBody(["channel": "C1", "text": "a&b c", "files": [["id": "F1"]], "broadcast": true])
        XCTAssertEqual(body, "broadcast=true&channel=C1&files=%5B%7B%22id%22%3A%22F1%22%7D%5D&text=a%26b%20c")
    }

    func testRoomCountStatus() {
        XCTAssertEqual(ChatRoomCount.status(workspaces: 1, servers: 4), "1 workspace, 4 servers")
        XCTAssertEqual(ChatRoomCount.status(workspaces: 1, servers: 0), "1 workspace")
        XCTAssertEqual(ChatRoomCount.status(workspaces: 0, servers: 0), "0 servers")
    }
}
