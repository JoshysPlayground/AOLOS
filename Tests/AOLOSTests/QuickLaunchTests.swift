import XCTest
@testable import AOLOS

final class QuickLaunchTests: XCTestCase {
    private let sources: QuickLaunchSources = {
        var s = QuickLaunchSources()
        s.people = [Buddy(id: "1", name: "Sarah Chen", username: "schen", presence: .offline),
                    Buddy(id: "slack:U2", name: "Sam Rivera", username: "sam", presence: .online),
                    Buddy(id: "fb:3", name: "Gene Parker", presence: .online)]
        s.rooms = [QuickRoom(id: "10", name: "general", serverName: "FFXI Linkshell"),
                   QuickRoom(id: "11", name: "general", serverName: "Ardyn Dev"),
                   QuickRoom(id: "12", name: "Lounge", serverName: "Ardyn Dev", voice: true)]
        s.favoriteRoomIDs = ["11"]
        s.keywords = ["mail", "radio", "settings"]
        return s
    }()

    private func titles(_ items: [QuickLaunchItem]) -> [String] { items.map(\.title) }

    func testMatchStrength() {
        XCTAssertEqual(QuickLaunchMatch.score("general", "General"), QuickLaunchMatch.exact)
        XCTAssertEqual(QuickLaunchMatch.score("gen", "general"), QuickLaunchMatch.prefix)
        XCTAssertEqual(QuickLaunchMatch.score("dev", "ios-dev"), QuickLaunchMatch.wordPrefix)
        XCTAssertEqual(QuickLaunchMatch.score("ffxi gen", "FFXI Linkshell general"), QuickLaunchMatch.allWords)
        XCTAssertEqual(QuickLaunchMatch.score("ene", "general"), QuickLaunchMatch.contains)
        XCTAssertNil(QuickLaunchMatch.score("xyz", "general"))
        XCTAssertEqual(QuickLaunchMatch.score("jose", "José"), QuickLaunchMatch.exact)
    }

    func testScopePrefixes() {
        XCTAssertEqual(QuickLaunchScope.parse("@sam").scope, .people)
        XCTAssertEqual(QuickLaunchScope.parse("# general").query, "general")
        XCTAssertEqual(QuickLaunchScope.parse("?swift").scope, .search)
        XCTAssertEqual(QuickLaunchScope.parse("hello").scope, .all)
    }

    func testWebAddressComesFirstAndIsDefault() {
        let url = URL(string: "https://apple.com")!
        let items = QuickLaunch.results(for: "apple.com", in: sources, url: url)
        XCTAssertEqual(items.first?.action, .website(url))
        XCTAssertEqual(QuickLaunch.defaultIndex(items), 0)
        XCTAssertEqual(items.last?.section, .search)
    }

    func testPersonPrefixMatchIsDefault() {
        let items = QuickLaunch.results(for: "sa", in: sources, url: nil)
        // Both Sams match equally; the online one sorts first.
        XCTAssertEqual(Array(titles(items).prefix(2)), ["Sam Rivera", "Sarah Chen"])
        XCTAssertEqual(QuickLaunch.defaultIndex(items).map { items[$0].title }, "Sam Rivera")
    }

    func testFavoriteRoomRanksFirst() {
        let items = QuickLaunch.results(for: "general", in: sources, url: nil).filter { $0.section == .rooms }
        XCTAssertEqual(items.map(\.subtitle), ["Ardyn Dev", "FFXI Linkshell"])
    }

    func testRoomByServerAndName() {
        let items = QuickLaunch.results(for: "#ffxi gen", in: sources, url: nil)
        XCTAssertEqual(items.map(\.subtitle), ["FFXI Linkshell"])
    }

    func testWeakMatchesFallBackToSearch() {
        // "ene" only appears inside "Gene" and "general", so Return should still search.
        let items = QuickLaunch.results(for: "ene", in: sources, url: nil)
        XCTAssertTrue(items.contains { $0.section == .people })
        XCTAssertEqual(QuickLaunch.defaultIndex(items).map { items[$0].action }, .search("ene"))
    }

    func testKeywordExactMatchWins() {
        let items = QuickLaunch.results(for: "mail", in: sources, url: nil)
        XCTAssertEqual(QuickLaunch.defaultIndex(items).map { items[$0].action }, .keyword("mail"))
    }

    func testSearchScopeOnlySearches() {
        XCTAssertEqual(QuickLaunch.results(for: "?sam", in: sources, url: nil).map(\.action), [.search("sam")])
    }

    func testEmptyQueryOffersRecentPeopleAndFavoriteRooms() {
        let items = QuickLaunch.results(for: "", in: sources, url: nil)
        XCTAssertEqual(items.filter { $0.section == .people }.count, 3)
        XCTAssertEqual(items.filter { $0.section == .rooms }.map(\.subtitle), ["Ardyn Dev"])
        XCTAssertFalse(items.contains { $0.section == .search })
    }

    func testAddingSourcesSkipsDuplicates() {
        var s = sources
        s.add(people: [Buddy(id: "1", name: "Sarah again", presence: .online), Buddy(id: "4", name: "New", presence: .online)])
        XCTAssertEqual(s.people.map(\.id), ["1", "slack:U2", "fb:3", "4"])
    }
}
