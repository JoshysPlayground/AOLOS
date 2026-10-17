import XCTest
@testable import AOLOS

final class SmoothScrollerTests: XCTestCase {
    func testNotchesKeepDirectionAndDampenSystemAcceleration() {
        XCTAssertEqual(SmoothScroller.notches(0), 0)
        XCTAssertEqual(SmoothScroller.notches(1), 1)
        XCTAssertEqual(SmoothScroller.notches(-1), -1)
        XCTAssertEqual(SmoothScroller.notches(0.3), 1)
        XCTAssertEqual(SmoothScroller.notches(4), 2)
        XCTAssertEqual(SmoothScroller.notches(-25), -3)
    }
}
