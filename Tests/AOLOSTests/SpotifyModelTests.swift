import XCTest
@testable import AOLOS

final class SpotifyModelTests: XCTestCase {
    private let trackJSON: [String: Any] = [
        "uri": "spotify:track:1",
        "name": "So What's New?",
        "duration_ms": 125_000,
        "external_urls": ["spotify": "https://open.spotify.com/track/1"],
        "artists": [["name": "Milton DeLugg", "external_urls": ["spotify": "https://open.spotify.com/artist/9"]]],
        "album": [
            "name": "Legends of Accordion",
            "external_urls": ["spotify": "https://open.spotify.com/album/5"],
            "images": [
                ["url": "https://i.scdn.co/640", "width": 640],
                ["url": "https://i.scdn.co/300", "width": 300],
                ["url": "https://i.scdn.co/64", "width": 64],
            ],
        ],
    ]

    func testTrackParsing() throws {
        let track = try XCTUnwrap(SpotifyTrack(json: trackJSON))
        XCTAssertEqual(track.artistLine, "Milton DeLugg")
        XCTAssertEqual(track.album, "Legends of Accordion")
        XCTAssertEqual(track.imageURL?.absoluteString, "https://i.scdn.co/300")
        XCTAssertEqual(track.artistURL?.absoluteString, "https://open.spotify.com/artist/9")
        XCTAssertNil(SpotifyTrack(json: ["name": "no uri"]))
    }

    func testPlayerStateProgressAdvancesOnlyWhilePlaying() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let json: [String: Any] = [
            "is_playing": true, "progress_ms": 4000, "item": trackJSON,
            "device": ["id": "d1", "name": "Josh's MacBook", "type": "Computer", "is_active": true, "volume_percent": 40],
            "context": ["uri": "spotify:playlist:abc"],
        ]
        let state = try XCTUnwrap(PlayerState(json: json, fetchedAt: start))
        XCTAssertEqual(state.progress(at: start.addingTimeInterval(2)), 6000)
        XCTAssertEqual(state.progress(at: start.addingTimeInterval(1000)), 125_000)
        XCTAssertEqual(state.device?.volume, 40)
        XCTAssertEqual(state.contextURI, "spotify:playlist:abc")

        var paused = json
        paused["is_playing"] = false
        XCTAssertEqual(PlayerState(json: paused, fetchedAt: start)?.progress(at: start.addingTimeInterval(5)), 4000)
    }

    func testClockFormatting() {
        XCTAssertEqual(PlayerState.clock(4_000), "0:04")
        XCTAssertEqual(PlayerState.clock(125_000), "2:05")
    }

    func testPlaylistStationStripsDescriptionMarkup() throws {
        let station = try XCTUnwrap(RadioStation.playlist([
            "uri": "spotify:playlist:abc", "name": "On the Rocks",
            "description": "Cheesy <a href=\"x\">retro</a> lounge &amp; more",
            "owner": ["display_name": "Josh"],
        ]))
        XCTAssertEqual(station.subtitle, "Cheesy retro lounge & more")
        XCTAssertEqual(station.contextURI, "spotify:playlist:abc")
    }

    func testPresetsRoundTripThroughConfig() throws {
        var config = AOLConfig()
        config.radioPresets = [RadioStation(title: "On the Rocks", subtitle: "Lounge", contextURI: "spotify:playlist:abc")]
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(AOLConfig.self, from: data).radioPresets, config.radioPresets)
        XCTAssertEqual(try JSONDecoder().decode(AOLConfig.self, from: Data("{}".utf8)).radioPresets, [])
    }
}
