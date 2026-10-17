import XCTest
@testable import AOLOS

final class WindowRestoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("windows-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    func testLayoutsAreKeptPerScreenName() {
        let browser = SavedWindow(kind: .browser, url: "https://www.aol.com/", profile: "browser",
                                  frame: CGRect(x: 40, y: 30, width: 800, height: 600), active: true)
        let room = SavedWindow(kind: .room, id: "123", name: "general", detail: "Friends",
                               frame: CGRect(x: 10, y: 10, width: 700, height: 500), minimized: true)
        WindowStore.save([browser, room], for: "Josh", to: url)
        WindowStore.save([], for: "Guest", to: url)
        XCTAssertEqual(WindowStore.load("josh", from: url), [browser, room])
        XCTAssertEqual(WindowStore.load("Guest", from: url), [])
        XCTAssertEqual(WindowStore.load("Nobody", from: url), [])
    }

    func testMissingOrBrokenFileLoadsNothing() throws {
        XCTAssertEqual(WindowStore.load("Josh", from: url), [])
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(WindowStore.load("Josh", from: url), [])
    }

    func testFrameIsPulledBackOntoASmallerDesktop() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let fit = WindowStore.fit(CGRect(x: 900, y: 650, width: 1200, height: 400), in: bounds,
                                  minSize: CGSize(width: 320, height: 200))
        XCTAssertEqual(fit, CGRect(x: 0, y: 300, width: 1000, height: 400))
        let small = WindowStore.fit(CGRect(x: 10, y: 10, width: 100, height: 50), in: bounds,
                                    minSize: CGSize(width: 320, height: 200))
        XCTAssertEqual(small.size, CGSize(width: 320, height: 200))
    }

    func testOnlyConversationsWaitForDiscord() {
        let frame = CGRect.zero
        XCTAssertTrue(SavedWindow(kind: .im, frame: frame).needsDiscord)
        XCTAssertTrue(SavedWindow(kind: .room, frame: frame).needsDiscord)
        XCTAssertFalse(SavedWindow(kind: .buddyList, frame: frame).needsDiscord)
        XCTAssertFalse(SavedWindow(kind: .service, frame: frame).needsDiscord)
    }
}
