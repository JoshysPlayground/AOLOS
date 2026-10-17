import AppKit
import XCTest
@testable import AOLOS

final class AppWindowStateTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let minSize = CGSize(width: 900, height: 600)

    func testFrameOnScreenIsUsable() {
        XCTAssertTrue(AppWindowState.isUsable(CGRect(x: 40, y: 40, width: 1200, height: 800), screens: [screen], minSize: minSize))
    }

    func testFrameOnAMissingDisplayIsNotUsable() {
        let offScreen = CGRect(x: 3200, y: 100, width: 1200, height: 800)
        XCTAssertFalse(AppWindowState.isUsable(offScreen, screens: [screen], minSize: minSize))
        let second = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        XCTAssertTrue(AppWindowState.isUsable(offScreen, screens: [screen, second], minSize: minSize))
    }

    func testFrameSmallerThanTheMinimumIsNotUsable() {
        XCTAssertFalse(AppWindowState.isUsable(CGRect(x: 0, y: 0, width: 400, height: 300), screens: [screen], minSize: minSize))
    }

    @MainActor
    func testTrackerSavesZoomAndFullScreen() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppWindowStateTests-\(UUID().uuidString)"))
        let state = AppWindowState(frame: CGRect(x: 10, y: 20, width: 1000, height: 700), zoomed: true, fullScreen: false)
        defaults.set(try JSONEncoder().encode(state), forKey: AppWindowTracker.defaultsKey)
        XCTAssertEqual(AppWindowTracker.load(from: defaults), state)

        let decoded = try JSONDecoder().decode(AppWindowState.self, from: JSONEncoder().encode(
            AppWindowState(frame: .zero, zoomed: false, fullScreen: true)))
        XCTAssertTrue(decoded.fullScreen)
    }
}
