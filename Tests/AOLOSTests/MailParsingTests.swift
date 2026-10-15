import XCTest
@testable import AOLOS

final class IMAPParserTests: XCTestCase {
    func testTrailingLiteralLength() {
        XCTAssertEqual(IMAPResponse.trailingLiteralLength("* 1 FETCH (BODY[] {42}"), 42)
        XCTAssertEqual(IMAPResponse.trailingLiteralLength("* 1 FETCH (BODY[] {7+}"), 7)
        XCTAssertNil(IMAPResponse.trailingLiteralLength("* 1 FETCH (UID 4)"))
    }

    func testFetchWithHeaderLiteral() {
        let header = Data("From: Ann <ann@example.com>\r\nSubject: Hi\r\n\r\n".utf8)
        let response = IMAPResponse(
            text: "* 12 FETCH (UID 345 FLAGS (\\Seen \\Flagged) INTERNALDATE \"15-Oct-2026 09:30:00 -0500\" "
                + "BODY[HEADER.FIELDS (FROM TO SUBJECT DATE)] {\(header.count)})",
            literals: [header])
        let items = IMAPParser.fetchItems(response)
        XCTAssertEqual(items?["UID"]?.text, "345")
        XCTAssertEqual(items?["FLAGS"]?.list?.compactMap(\.text), ["\\Seen", "\\Flagged"])
        XCTAssertEqual(items?["BODY[HEADER.FIELDS (FROM TO SUBJECT DATE)]"]?.data, header)
        XCTAssertNotNil(MailDate.parseInternal(items?["INTERNALDATE"]?.text))
    }

    func testQuotedStringEscapesAndNil() {
        var parser = IMAPParser(IMAPResponse(text: #"("a \"b\" c" NIL atom)"#, literals: []))
        XCTAssertEqual(parser.next(), .list([.string(Data(#"a "b" c"#.utf8)), .nilValue, .atom("atom")]))
    }

    func testListEntry() {
        let entry = IMAPParser.listEntry(IMAPResponse(text: #"* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail""#, literals: []))
        XCTAssertEqual(entry?.name, "[Gmail]/Sent Mail")
        XCTAssertEqual(entry?.attributes, ["\\HasNoChildren", "\\Sent"])
    }

    func testSearchAndUIDSet() {
        XCTAssertEqual(IMAPParser.searchUIDs(IMAPResponse(text: "* SEARCH 3 9 10", literals: [])), [3, 9, 10])
        XCTAssertEqual(IMAPParser.searchUIDs(IMAPResponse(text: "* SEARCH", literals: [])), [])
        XCTAssertEqual(IMAPParser.uidSet([9, 1, 2, 3, 7, 10]), "1:3,7,9:10")
    }
}

final class MIMETests: XCTestCase {
    func testEncodedWords() {
        XCTAssertEqual(MIME.decodeWords("=?UTF-8?B?SGVsbG8g8J+Riw==?="), "Hello \u{1F44B}")
        XCTAssertEqual(MIME.decodeWords("=?ISO-8859-1?Q?Caf=E9_au_lait?="), "Caf\u{E9} au lait")
        XCTAssertEqual(MIME.decodeWords("=?UTF-8?Q?a?= =?UTF-8?Q?b?= plain"), "ab plain")
    }

    func testQuotedPrintableSoftBreaks() {
        let decoded = MIME.quotedPrintable(Data("caf=C3=A9 long=\r\nline".utf8))
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "caf\u{E9} longline")
    }

    func testMultipartAlternativePrefersHTMLAndInlinesImages() {
        let raw = """
        From: "Ann Example" <ann@example.com>\r
        To: me@example.com\r
        Subject: =?UTF-8?Q?Hello_there?=\r
        Content-Type: multipart/related; boundary="REL"\r
        \r
        --REL\r
        Content-Type: multipart/alternative; boundary="ALT"\r
        \r
        --ALT\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain body\r
        --ALT\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        <p>HTML <b>body</b></p><img src=3D"cid:logo@x">\r
        --ALT--\r
        --REL\r
        Content-Type: image/png\r
        Content-ID: <logo@x>\r
        Content-Transfer-Encoding: base64\r
        \r
        iVBORw0KGgo=\r
        --REL--\r

        """
        let summary = MailSummary(uid: 1, folder: "INBOX", seen: false, date: Date(), from: "", to: "", subject: "")
        let message = MailMessage(summary: summary, raw: Data(raw.utf8))
        XCTAssertEqual(message.subject, "Hello there")
        XCTAssertEqual(MailAddress.name(message.from), "Ann Example")
        XCTAssertTrue(message.html.contains("<b>body</b>"))
        XCTAssertTrue(message.html.contains("data:image/png;base64,"))
        XCTAssertFalse(message.html.contains("cid:"))
        XCTAssertEqual(message.plainText, "Plain body")
        XCTAssertFalse(message.hasRemoteContent)
    }

    func testRemoteContentDetection() {
        let raw = "Content-Type: text/html\r\n\r\n<img src=\"https://tracker.example/p.gif\">"
        let summary = MailSummary(uid: 1, folder: "INBOX", seen: true, date: Date(), from: "", to: "", subject: "")
        XCTAssertTrue(MailMessage(summary: summary, raw: Data(raw.utf8)).hasRemoteContent)
    }

    func testAttachmentFilename() {
        let part = MIMEPart(Data("Content-Type: application/pdf; name=\"a.pdf\"\r\nContent-Disposition: attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf\r\n\r\nx".utf8))
        XCTAssertEqual(part.filename, "r\u{E9}sum\u{E9}.pdf")
        XCTAssertEqual(part.disposition, "attachment")
    }
}

final class MailHelperTests: XCTestCase {
    func testAddressSplitting() {
        let list = MailAddress.split(#""Doe, Jane" <jane@example.com>, bob@example.com"#)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(MailAddress.email(list[0]), "jane@example.com")
        XCTAssertEqual(MailAddress.name(list[0]), "Doe, Jane")
        XCTAssertEqual(MailAddress.email(list[1]), "bob@example.com")
    }

    func testHeaderDateWithComment() {
        XCTAssertNotNil(MailDate.parse("Thu, 15 Oct 2026 09:30:00 -0500 (CDT)"))
        XCTAssertNotNil(MailDate.parse("15 Oct 2026 09:30:00 +0000"))
    }

    func testOutgoingMailStripsHeaderInjection() {
        let mail = OutgoingMail(from: "me@example.com", to: ["you@example.com"], cc: [],
                                subject: "Hi\r\nBcc: evil@example.com", body: "Hello", inReplyTo: nil, references: nil)
        let text = String(decoding: mail.rfc822(), as: UTF8.self)
        XCTAssertFalse(text.contains("\r\nBcc:"))
        XCTAssertEqual(mail.recipients, ["you@example.com"])
    }

    func testDotStuffing() {
        let out = SMTPClient.dotStuffed(Data("a\r\n.b\r\n".utf8))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "a\r\n..b\r\n")
    }

    func testPKCEChallengeMatchesRFC7636Example() {
        XCTAssertEqual(GoogleAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testIDTokenEmail() {
        let payload = GoogleAuth.base64URL(Data(#"{"email":"me@example.com"}"#.utf8))
        XCTAssertEqual(GoogleAuth.email(fromIDToken: "x.\(payload).y"), "me@example.com")
    }

    func testOutgoingMultipartRoundTrip() {
        let file = MailAttachment(filename: "notes.txt", mimeType: "text/plain", data: Data("attached".utf8))
        let mail = OutgoingMail(from: "me@example.com", to: ["you@example.com"], cc: [], subject: "Hi",
                                body: "Plain body", inReplyTo: nil, references: nil,
                                html: "<b>Rich body</b>", attachments: [file], returnReceipt: true)
        let raw = mail.rfc822()
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(text.contains("Disposition-Notification-To: me@example.com"))

        let parsed = MailMessage(summary: MailSummary(uid: 1, folder: "INBOX", seen: true, date: Date(),
                                                      from: "", to: "", subject: ""), raw: raw)
        XCTAssertTrue(parsed.html.contains("<b>Rich body</b>"))
        XCTAssertEqual(parsed.plainText, "Plain body")
        XCTAssertEqual(parsed.attachments, ["notes.txt"])
    }
}
