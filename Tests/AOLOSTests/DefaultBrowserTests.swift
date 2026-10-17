import XCTest
@testable import AOLOS

final class DefaultBrowserTests: XCTestCase {
    func testWebAndFileURLsOpen() {
        for address in ["https://www.aol.com/", "http://example.com/a?b=c", "HTTPS://Example.com"] {
            XCTAssertNotNil(DefaultBrowser.page(for: URL(string: address)!), address)
        }
        XCTAssertNotNil(DefaultBrowser.page(for: URL(fileURLWithPath: "/tmp/page.html")))
    }

    func testOtherSchemesAreIgnored() {
        for address in ["mailto:a@b.com", "ftp://example.com", "aolos://x", "https:///nohost"] {
            XCTAssertNil(DefaultBrowser.page(for: URL(string: address)!), address)
        }
    }
}
