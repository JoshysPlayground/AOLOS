import XCTest
@testable import AOLOS

final class MailAccountTests: XCTestCase {
    func testMigrationMovesSingleAccount() throws {
        let changes = try XCTUnwrap(GoogleAccountKeys.migration([
            "google.email": "Josh@Example.com",
            "google.refreshToken": "tok",
            "google.clientID": "id",
        ]))
        XCTAssertEqual(changes["google.refreshToken.josh@example.com"], .some("tok"))
        XCTAssertEqual(GoogleAccountKeys.decodeList(changes["google.accounts"] ?? nil), ["Josh@Example.com"])
        XCTAssertEqual(changes["google.email"], .some(nil))
        XCTAssertEqual(changes["google.refreshToken"], .some(nil))
        XCTAssertNil(changes["google.clientID"])
    }

    func testMigrationDropsAccountWithoutToken() throws {
        let changes = try XCTUnwrap(GoogleAccountKeys.migration(["google.email": "a@example.com"]))
        XCTAssertNil(changes["google.accounts"] ?? nil)
        XCTAssertEqual(changes["google.email"], .some(nil))
    }

    func testMigrationSkipsWhenListExistsOrNothingSaved() {
        XCTAssertNil(GoogleAccountKeys.migration([:]))
        XCTAssertNil(GoogleAccountKeys.migration([
            "google.accounts": GoogleAccountKeys.encodeList(["a@example.com"]),
            "google.email": "a@example.com",
        ]))
    }

    func testAccountListRoundTrip() {
        let list = ["a@example.com", "b@example.com"]
        XCTAssertEqual(GoogleAccountKeys.decodeList(GoogleAccountKeys.encodeList(list)), list)
        XCTAssertEqual(GoogleAccountKeys.decodeList(nil), [])
        XCTAssertEqual(GoogleAccountKeys.decodeList("not json"), [])
    }

    func testReplyGoesOutFromReceivingAccount() {
        let accounts = ["home@gmail.com", "work@company.com"]
        XCTAssertEqual(MailCenter.replyAccount(account: "work@company.com", to: "", cc: "", accounts: accounts), "work@company.com")
        XCTAssertEqual(MailCenter.replyAccount(account: "WORK@company.com", to: "", cc: "", accounts: accounts), "work@company.com")
        XCTAssertEqual(MailCenter.replyAccount(account: "", to: "Ann <ann@x.com>", cc: "Work <Work@Company.com>", accounts: accounts),
                       "work@company.com")
        XCTAssertEqual(MailCenter.replyAccount(account: "", to: "ann@x.com", cc: "", accounts: accounts), "home@gmail.com")
        XCTAssertNil(MailCenter.replyAccount(account: "", to: "", cc: "", accounts: []))
    }

    func testMergeSortsAcrossAccountsNewestFirst() {
        func summary(_ uid: UInt32, _ minutes: Double, _ account: String) -> MailSummary {
            MailSummary(uid: uid, folder: "INBOX", seen: false, date: Date(timeIntervalSince1970: minutes * 60),
                        from: "", to: "", subject: "", account: account)
        }
        let merged = MailCenter.merge([[summary(1, 30, "a"), summary(2, 10, "a")], [summary(1, 20, "b")]])
        XCTAssertEqual(merged.map(\.account), ["a", "b", "a"])
        XCTAssertEqual(merged.map(\.uid), [1, 1, 2])
    }

    func testSameUIDInTwoAccountsIsDistinct() {
        let a = MailSummary(uid: 7, folder: "INBOX", seen: true, date: Date(timeIntervalSince1970: 0), from: "", to: "", subject: "",
                            account: "a@example.com")
        var b = a
        b.account = "b@example.com"
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 2)
    }
}
