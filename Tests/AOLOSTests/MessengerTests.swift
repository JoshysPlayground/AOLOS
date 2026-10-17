import XCTest
@testable import AOLOS

final class MessengerTests: XCTestCase {
    func testServiceKindFromID() {
        XCTAssertEqual(ChatServiceKind(id: "fb:100001"), .messenger)
        XCTAssertEqual(ChatServiceKind(id: "slack:U123"), .slack)
        XCTAssertEqual(ChatServiceKind(id: "80351110224678912"), .discord)
        XCTAssertEqual(ChatServiceKind(id: "fb:1").name, "Messenger")
    }

    func testMessengerServiceURL() {
        XCTAssertTrue(MessengerBridge.isMessengerService("https://www.facebook.com/messages/t/"))
        XCTAssertTrue(MessengerBridge.isMessengerService("https://facebook.com/messages/"))
        XCTAssertFalse(MessengerBridge.isMessengerService("https://www.facebook.com/"))
        XCTAssertFalse(MessengerBridge.isMessengerService("https://www.messenger.com/"))
        XCTAssertFalse(MessengerBridge.isMessengerHost("evilfacebook.com"))
    }

    func testDefaultConfigHasMessenger() {
        XCTAssertEqual(AOLConfig().service("messenger")?.url, "https://www.facebook.com/messages/t/")
    }

    func testInterleaveAlternatesAndKeepsLeftovers() {
        XCTAssertEqual(RecentBuddies.interleave([1, 2, 3], [10]), [1, 10, 2, 3])
        XCTAssertEqual(RecentBuddies.interleave([Int](), [10, 11]), [10, 11])
    }
}
