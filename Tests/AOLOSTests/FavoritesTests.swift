import XCTest
@testable import AOLOS

final class FavoritesTests: XCTestCase {
    func testConfigWithoutFavoritesDecodesEmpty() throws {
        let config = try JSONDecoder().decode(AOLConfig.self, from: Data(#"{"screenName":"Josh"}"#.utf8))
        XCTAssertEqual(config.favorites, [])
    }

    func testFavoritesRoundTripInOrder() throws {
        var config = AOLConfig()
        config.favorites = [Favorite(title: "AOL", url: "https://www.aol.com/"),
                            Favorite(title: "Apple", url: "https://www.apple.com/")]
        let decoded = try JSONDecoder().decode(AOLConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.favorites, config.favorites)
    }
}
