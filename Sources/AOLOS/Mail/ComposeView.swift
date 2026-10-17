import AppKit
import UniformTypeIdentifiers

/// The AOL 9 Write Mail window: address boxes, a formatting bar, the message, and big actions on the right.
final class ComposeView: FlippedView {
    var onSend: (() -> Void)?
    var onAddressBook: ((NSView) -> Void)?

    let toView: NSTextView
    let ccView: NSTextView
    let subjectField = NSTextField()
    /// Shown on the Subject row when more than one Gmail account is signed in.
    private let fromPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let accounts: [String]
    let textView: NSTextView
    private let toScroll: NSScrollView
    private let ccScroll: NSScrollView
    private let bodyScroll: NSScrollView
    private let formatBar = FlippedView()
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let boldButton = ChromeButton(title: "B")
    private let italicButton = ChromeButton(title: "I")
    private let underlineButton = ChromeButton(title: "U")
    private let colorButton = ChromeButton(title: "A", symbol: "paintbrush.pointed.fill")
    private let alignButton = ChromeButton(symbol: "text.alignleft")
    private let attachButton = PillButton(title: "Attach File", style: .blue)
    private let detachButton = PillButton(title: "Detach File", style: .blue)
    private let spellButton = PillButton(title: "Spell Check", style: .blue)
    private let receipt = NSButton(checkboxWithTitle: "Request \"Return Receipt\"", target: nil, action: nil)
    private let attachmentLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var sideButtons: [ToolbarButton] = []
    private(set) var attachments: [MailAttachment] = []

    static let fonts = ["Arial", "Tahoma", "Verdana", "Georgia", "Times New Roman", "Courier New", "Comic Sans MS"]
    static let sizes = [8, 9, 10, 11, 12, 13, 14, 16, 18, 24, 36]
    static let defaultFont = NSFont(name: "Arial", size: 13) ?? .systemFont(ofSize: 13)
    static let maxAttachmentBytes = 24 * 1024 * 1024

    init(to: String, cc: String, subject: String, body: String, accounts: [String] = [], from: String? = nil) {
        self.accounts = accounts
        toScroll = NSTextView.scrollableTextView()
        ccScroll = NSTextView.scrollableTextView()
        bodyScroll = NSTextView.scrollableTextView()
        toView = toScroll.documentView as! NSTextView
        ccView = ccScroll.documentView as! NSTextView
        textView = bodyScroll.documentView as! NSTextView
        super.init(frame: .zero)

        for (view, value) in [(toView, to), (ccView, cc)] {
            view.string = value
            view.font = Theme.ui(12)
            view.isRichText = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.textContainerInset = NSSize(width: 3, height: 4)
        }
        for scroll in [toScroll, ccScroll, bodyScroll] {
            scroll.borderType = .bezelBorder
            scroll.hasVerticalScroller = true
        }
        subjectField.stringValue = subject
        subjectField.font = Theme.ui(12)
        fromPopup.addItems(withTitles: accounts)
        if let from { fromPopup.selectItem(withTitle: from) }
        fromPopup.controlSize = .small
        fromPopup.font = Theme.ui(11)
        fromPopup.isHidden = accounts.count < 2

        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.typingAttributes = [.font: Self.defaultFont, .foregroundColor: NSColor.black]
        textView.textStorage?.setAttributedString(NSAttributedString(string: body, attributes: textView.typingAttributes))
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        fontPopup.addItems(withTitles: Self.fonts)
        fontPopup.selectItem(withTitle: "Arial")
        fontPopup.target = self
        fontPopup.action = #selector(fontChosen)
        sizePopup.addItems(withTitles: Self.sizes.map(String.init))
        sizePopup.selectItem(withTitle: "13")
        sizePopup.target = self
        sizePopup.action = #selector(fontChosen)
        [fontPopup, sizePopup].forEach { $0.controlSize = .small; $0.font = Theme.ui(11) }
        boldButton.action = { [weak self] in self?.toggle(.boldFontMask) }
        italicButton.action = { [weak self] in self?.toggle(.italicFontMask) }
        underlineButton.action = { [weak self] in self?.toggleUnderline() }
        colorButton.action = { [weak self] in self?.showColors() }
        alignButton.action = { [weak self] in self?.showAlignment() }
        [fontPopup, sizePopup, boldButton, italicButton, underlineButton, colorButton, alignButton].forEach(formatBar.addSubview)

        attachButton.action = { [weak self] in self?.attach() }
        detachButton.action = { [weak self] in self?.detach() }
        spellButton.action = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.textView)
            self.textView.checkSpelling(nil)
            self.textView.showGuessPanel(nil)
        }
        receipt.font = Theme.ui(11)
        attachmentLabel.font = Theme.ui(11)
        attachmentLabel.textColor = Theme.mutedText
        attachmentLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = Theme.ui(11, bold: true)
        statusLabel.textColor = Theme.rgb(170, 30, 30)
        statusLabel.lineBreakMode = .byTruncatingTail

        let send = ToolbarButton(title: "Send Now", name: "sendnow", symbol: "paperplane.fill", colors: [Theme.aolBlue])
        send.action = { [weak self] in self?.onSend?() }
        let later = ToolbarButton(title: "Send Later", name: "sendlater", symbol: "clock.fill", colors: [Theme.aolBlue])
        later.available = false
        later.toolTip = "Not available yet"
        let book = ToolbarButton(title: "Address Book", name: "addressbook", symbol: "book.closed.fill", colors: [Theme.aolBlue])
        book.action = { [weak self, weak book] in if let self, let book { self.onAddressBook?(book) } }
        let print = ToolbarButton(title: "Print", name: "print", symbol: "printer.fill", colors: [Theme.text])
        print.action = { [weak self] in self?.printMessage() }
        sideButtons = [send, later, book, print]

        ([toScroll, ccScroll, subjectField, fromPopup, formatBar, bodyScroll, attachButton, detachButton, spellButton, receipt,
          attachmentLabel, statusLabel] + sideButtons).forEach(addSubview)
        updateAttachments()
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredFirstResponder: NSView { toView.string.isEmpty ? toView : textView }

    /// The account this mail goes out from.
    var fromAccount: String { fromPopup.titleOfSelectedItem ?? accounts.first ?? "" }

    private var showsFrom: Bool { !fromPopup.isHidden }

    override func layout() {
        super.layout()
        let side: CGFloat = 92
        let right = bounds.width - side - 16
        let half = (right - 8) / 2
        toScroll.frame = NSRect(x: 84, y: 8, width: half - 84, height: 58)
        ccScroll.frame = NSRect(x: half + 84, y: 8, width: right - half - 84, height: 58)
        let fromWidth: CGFloat = showsFrom ? min(240, max(150, (right - 84) * 0.4)) : 0
        subjectField.frame = NSRect(x: 84, y: 74, width: right - 84 - (showsFrom ? fromWidth + 58 : 0), height: 22)
        fromPopup.frame = NSRect(x: right - fromWidth, y: 74, width: fromWidth, height: 22)
        formatBar.frame = NSRect(x: 6, y: 102, width: right - 6, height: 28)
        var x: CGFloat = 0
        fontPopup.frame = NSRect(x: x, y: 3, width: 132, height: 22); x += 136
        sizePopup.frame = NSRect(x: x, y: 3, width: 56, height: 22); x += 64
        for b in [boldButton, italicButton, underlineButton] {
            b.frame = NSRect(x: x, y: 3, width: 24, height: 22)
            x += 27
        }
        x += 8
        colorButton.frame = NSRect(x: x, y: 3, width: 44, height: 22); x += 50
        alignButton.frame = NSRect(x: x, y: 3, width: 32, height: 22)

        let bottom: CGFloat = 36
        bodyScroll.frame = NSRect(x: 6, y: 134, width: right - 6, height: max(80, bounds.height - 134 - bottom - 24))
        attachmentLabel.frame = NSRect(x: 8, y: bodyScroll.frame.maxY + 3, width: right - 10, height: 16)
        let by = bounds.height - bottom + 6
        attachButton.frame = NSRect(x: 8, y: by, width: 96, height: 24)
        detachButton.frame = NSRect(x: 110, y: by, width: 96, height: 24)
        statusLabel.frame = NSRect(x: 214, y: by + 4, width: max(0, right - 214 - 340), height: 16)
        spellButton.frame = NSRect(x: right - 100, y: by, width: 100, height: 24)
        receipt.frame = NSRect(x: right - 300, y: by + 2, width: 190, height: 20)

        var sy: CGFloat = 12
        for button in sideButtons {
            button.frame = NSRect(x: bounds.width - side - 2, y: sy, width: side - 4, height: 62)
            sy += 70
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient([Theme.rgb(232, 240, 252), Theme.rgb(204, 222, 246)], in: bounds)
        let side = NSRect(x: bounds.width - 100, y: 0, width: 100, height: bounds.height)
        Theme.gradient([Theme.rgb(214, 228, 248), Theme.rgb(190, 210, 240)], in: side)
        Theme.toolbarLine.setFill()
        NSRect(x: side.minX, y: 0, width: 1, height: bounds.height).fill()
        let half = (bounds.width - 92 - 16 - 8) / 2
        var labels: [(String, CGFloat, CGFloat)] = [("Send To:", 8, 10), ("Copy To:", half + 8, 10), ("Subject:", 8, 76)]
        if showsFrom { labels.append(("From:", fromPopup.frame.minX - 50, 76)) }
        for (label, x, y) in labels {
            drawText(label, font: Theme.ui(12, bold: true), color: Theme.text, in: NSRect(x: x, y: y, width: 74, height: 18))
        }
        let bar = NSBezierPath(roundedRect: formatBar.frame.insetBy(dx: -2, dy: 0), xRadius: 4, yRadius: 4)
        Theme.gradient([Theme.rgb(250, 252, 255), Theme.rgb(222, 234, 250)], in: bar)
        Theme.toolbarLine.setStroke()
        bar.stroke()
    }

    func makeOutgoing(from: String, inReplyTo: String?, references: String?) -> OutgoingMail {
        let storage = textView.attributedString()
        let html = try? storage.data(from: NSRange(location: 0, length: storage.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ])
        return OutgoingMail(
            from: from,
            to: MailAddress.split(toView.string),
            cc: MailAddress.split(ccView.string),
            subject: subjectField.stringValue,
            body: textView.string,
            inReplyTo: inReplyTo,
            references: references,
            html: html.map { String(decoding: $0, as: UTF8.self) },
            attachments: attachments,
            returnReceipt: receipt.state == .on)
    }

    func addAttachment(_ file: MailAttachment) {
        attachments.append(file)
        updateAttachments()
    }

    func insertAddress(_ address: String) {
        let current = toView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        toView.string = current.isEmpty ? address : current + ", " + address
    }

    func setBusy(_ busy: Bool) {
        sideButtons.first?.isEnabled = !busy
        statusLabel.textColor = busy ? Theme.rgb(20, 60, 140) : Theme.rgb(170, 30, 30)
        statusLabel.stringValue = busy ? "Sending your mail..." : ""
    }

    func showStatus(_ text: String) {
        statusLabel.textColor = Theme.rgb(170, 30, 30)
        statusLabel.stringValue = text
    }

    private func updateAttachments() {
        detachButton.isEnabled = !attachments.isEmpty
        let total = attachments.reduce(0) { $0 + $1.data.count }
        attachmentLabel.stringValue = attachments.isEmpty
            ? "No files attached."
            : "Attached: " + attachments.map(\.filename).joined(separator: ", ")
                + " (" + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file) + ")"
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let total = attachments.reduce(data.count) { $0 + $1.data.count }
            guard total <= Self.maxAttachmentBytes else {
                showStatus("Gmail limits attachments to 25 MB in total.")
                break
            }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            attachments.append(MailAttachment(filename: url.lastPathComponent, mimeType: type, data: data))
        }
        updateAttachments()
    }

    private func detach() {
        guard !attachments.isEmpty else { return }
        if attachments.count == 1 {
            attachments.removeAll()
            updateAttachments()
            return
        }
        let menu = NSMenu()
        for (i, file) in attachments.enumerated() {
            menu.addItem(ActionItem(file.filename) { [weak self] in
                self?.attachments.remove(at: i)
                self?.updateAttachments()
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: detachButton.bounds.height), in: detachButton)
    }

    private func printMessage() {
        let operation = NSPrintOperation(view: textView)
        operation.showsPrintPanel = true
        operation.run()
    }

    private var selection: NSRange { textView.selectedRange() }

    /// Applies a change to the selected text, or to the typing style when nothing is selected.
    private func applyAttributes(_ change: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        let range = selection
        if range.length == 0 {
            textView.typingAttributes = change(textView.typingAttributes)
        } else if let storage = textView.textStorage, textView.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttributes(in: range) { attrs, sub, _ in
                storage.setAttributes(change(attrs), range: sub)
            }
            storage.endEditing()
            textView.didChangeText()
        }
        window?.makeFirstResponder(textView)
    }

    @objc private func fontChosen() {
        let family = fontPopup.titleOfSelectedItem ?? "Arial"
        let size = CGFloat(Int(sizePopup.titleOfSelectedItem ?? "13") ?? 13)
        applyAttributes { attrs in
            var a = attrs
            let current = (attrs[.font] as? NSFont) ?? Self.defaultFont
            let traits = NSFontManager.shared.traits(of: current)
            var font = NSFontManager.shared.font(withFamily: family, traits: traits, weight: 5, size: size)
                ?? NSFont(name: family, size: size) ?? Self.defaultFont
            if traits.contains(.boldFontMask) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            a[.font] = font
            return a
        }
    }

    private func toggle(_ trait: NSFontTraitMask) {
        let probe = (selection.length > 0 ? textView.textStorage?.attribute(.font, at: selection.location, effectiveRange: nil) : nil)
            as? NSFont ?? (textView.typingAttributes[.font] as? NSFont) ?? Self.defaultFont
        let turnOn = !NSFontManager.shared.traits(of: probe).contains(trait)
        applyAttributes { attrs in
            var a = attrs
            let font = (attrs[.font] as? NSFont) ?? Self.defaultFont
            a[.font] = turnOn ? NSFontManager.shared.convert(font, toHaveTrait: trait)
                              : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            return a
        }
    }

    private func toggleUnderline() {
        let probe = selection.length > 0
            ? textView.textStorage?.attribute(.underlineStyle, at: selection.location, effectiveRange: nil) as? Int
            : textView.typingAttributes[.underlineStyle] as? Int
        let on = (probe ?? 0) == 0
        applyAttributes { attrs in
            var a = attrs
            a[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil
            return a
        }
    }

    private func showColors() {
        let menu = NSMenu()
        let colors: [(String, NSColor)] = [
            ("Black", .black), ("Navy", Theme.rgb(0, 0, 128)), ("Blue", Theme.rgb(0, 80, 220)),
            ("Red", Theme.rgb(200, 20, 20)), ("Green", Theme.rgb(0, 128, 0)), ("Purple", Theme.rgb(110, 30, 160)),
            ("Orange", Theme.rgb(230, 120, 0)), ("Gray", Theme.rgb(110, 110, 110)),
        ]
        for (name, color) in colors {
            let item = ActionItem(name) { [weak self] in
                self?.applyAttributes { attrs in
                    var a = attrs
                    a[.foregroundColor] = color
                    return a
                }
            }
            let swatch = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                color.setFill()
                rect.fill()
                return true
            }
            item.image = swatch
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: colorButton.bounds.height), in: colorButton)
    }

    private func showAlignment() {
        let menu = NSMenu()
        for (name, alignment) in [("Left", NSTextAlignment.left), ("Center", .center), ("Right", .right)] {
            menu.addItem(ActionItem(name) { [weak self] in
                guard let self else { return }
                let range = self.selection.length > 0 ? self.selection
                    : (self.textView.string as NSString).paragraphRange(for: self.selection)
                self.textView.setAlignment(alignment, range: range)
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: alignButton.bounds.height), in: alignButton)
    }
}
