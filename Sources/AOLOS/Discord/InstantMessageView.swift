import AppKit

/// IM text views. Return sends and Shift-Return adds a new line. Dropped or pasted files become attachments.
final class IMInputView: NSTextView {
    var onSend: (() -> Void)?
    var onFiles: (([DiscordBridge.Attachment]) -> Void)?

    override func keyDown(with event: NSEvent) {
        if isEditable, event.keyCode == 36 || event.keyCode == 76, !event.modifierFlags.contains(.shift) {
            onSend?()
        } else {
            super.keyDown(with: event)
        }
    }

    func acceptFileDrops() {
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        IMAttachments.read(sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        IMAttachments.read(sender.draggingPasteboard).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = IMAttachments.read(sender.draggingPasteboard)
        guard !files.isEmpty, let onFiles else { return super.performDragOperation(sender) }
        onFiles(files)
        return true
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let files = pasteboard.string(forType: .string) == nil ? IMAttachments.read(pasteboard) : []
        if !files.isEmpty, let onFiles { onFiles(files) } else { super.paste(sender) }
    }
}

enum IMAttachments {
    /// Discord's default upload limit for accounts without Nitro.
    static let maxBytes = 10 * 1024 * 1024

    static func read(_ pasteboard: NSPasteboard) -> [DiscordBridge.Attachment] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            return urls.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return DiscordBridge.Attachment(name: url.lastPathComponent, type: mimeType(url.pathExtension), data: data)
            }
        }
        if let png = pasteboard.data(forType: .png) {
            return [DiscordBridge.Attachment(name: "image.png", type: "image/png", data: png)]
        }
        if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return [DiscordBridge.Attachment(name: "image.png", type: "image/png", data: png)]
        }
        return []
    }

    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }
}

/// The formatting strip between the transcript and the entry box. Buttons wrap the selection in Discord markdown.
final class IMFormatBar: FlippedView {
    var onWrap: ((String) -> Void)?
    var onClearAttachments: (() -> Void)?
    var attachments: [String] = [] { didSet { needsDisplay = true } }

    private var attachmentRect: NSRect {
        let x = 8 + CGFloat(items.count) * 30 + 10
        return NSRect(x: x, y: 0, width: max(0, bounds.width - x - 6), height: bounds.height)
    }
    private let items: [(String, String, NSFont)] = [
        ("B", "**", Theme.ui(12, bold: true)),
        ("I", "*", NSFontManager.shared.convert(Theme.ui(12), toHaveTrait: .italicFontMask)),
        ("U", "__", Theme.ui(12)),
        ("S", "~~", Theme.ui(12)),
        ("</>", "`", Theme.ui(11, bold: true)),
    ]

    private func rects() -> [NSRect] {
        items.indices.map { NSRect(x: 8 + CGFloat($0) * 30, y: 3, width: 26, height: bounds.height - 6) }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        Theme.chromeShade.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        for (item, rect) in zip(items, rects()) {
            let attributed = NSMutableAttributedString(string: item.0, attributes: [.font: item.2, .foregroundColor: Theme.aolBlue])
            if item.1 == "__" {
                attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                        range: NSRange(location: 0, length: attributed.length))
            }
            if item.1 == "~~" {
                attributed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                        range: NSRange(location: 0, length: attributed.length))
            }
            let size = attributed.size()
            attributed.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
        if !attachments.isEmpty {
            let rect = attachmentRect
            Icons.symbol("paperclip", size: 11, colors: [Theme.aolBlue])?
                .draw(in: NSRect(x: rect.minX, y: rect.midY - 7, width: 14, height: 14), from: .zero,
                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            drawText(attachments.joined(separator: ", ") + "   (click to remove)", font: Theme.ui(11), color: Theme.text,
                     in: NSRect(x: rect.minX + 18, y: rect.minY, width: rect.width - 18, height: rect.height))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = rects().firstIndex(where: { $0.contains(p) }) {
            onWrap?(items[i].1)
        } else if !attachments.isEmpty, attachmentRect.contains(p) {
            onClearAttachments?()
        }
    }
}

/// An AIM Instant Message window for one Discord direct message conversation.
final class InstantMessageView: FlippedView {
    var onSend: ((String, [DiscordBridge.Attachment]) -> Void)?
    var onInfo: (() -> Void)?
    private var pending: [DiscordBridge.Attachment] = [] {
        didSet { formatBar.attachments = pending.map(\.name) }
    }

    let buddyID: String
    private(set) var buddyName: String
    private var myID: String
    private var myName: String
    private var shownIDs: Set<String> = []

    private let transcriptScroll = NSScrollView()
    private let transcript = IMInputView()
    private let formatBar = IMFormatBar()
    private let inputScroll = NSScrollView()
    let input = IMInputView()
    private let bottom = ButtonBar()
    private let icon = NSImageView()
    private let info = ChromeButton(title: "Get Info", symbol: "person.text.rectangle")
    private let send = ChromeButton(title: "Send", symbol: "paperplane.fill", prominent: true)
    private var avatarURL: URL?

    /// AIM shows your own screen name in red and your buddy's in blue.
    private static let myColor = Theme.rgb(220, 0, 0)
    private static let buddyColor = Theme.rgb(0, 0, 210)
    private static let bodyFont = NSFont(name: "Times New Roman", size: 15) ?? .systemFont(ofSize: 14)
    private static let nameFont = NSFont(name: "Times New Roman Bold", size: 15) ?? .boldSystemFont(ofSize: 14)

    init(buddy: Buddy, myID: String, myName: String) {
        buddyID = buddy.id
        buddyName = buddy.name
        avatarURL = buddy.avatarURL
        self.myID = myID
        self.myName = myName
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 420))

        configure(transcriptScroll, transcript, editable: false)
        configure(inputScroll, input, editable: true)
        input.font = Self.bodyFont
        input.typingAttributes = [.font: Self.bodyFont, .foregroundColor: Theme.text]
        input.onSend = { [weak self] in self?.sendTapped() }
        formatBar.onWrap = { [weak self] marker in self?.wrap(marker) }
        formatBar.onClearAttachments = { [weak self] in self?.pending = [] }
        for view in [input, transcript] {
            view.acceptFileDrops()
            view.onFiles = { [weak self] files in self?.attach(files) }
        }

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 4
        icon.layer?.masksToBounds = true
        loadIcon()

        info.action = { [weak self] in self?.onInfo?() }
        send.action = { [weak self] in self?.sendTapped() }
        bottom.colors = [Theme.rgb(236, 233, 216), Theme.rgb(214, 210, 192)]
        [transcriptScroll, formatBar, inputScroll, bottom].forEach(addSubview)
        bottom.addSubview(icon)
        bottom.addSubview(send)
        bottom.addSubview(info)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ scroll: NSScrollView, _ text: NSTextView, editable: Bool) {
        text.isEditable = editable
        text.isSelectable = true
        text.isRichText = false
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.backgroundColor = .white
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 6
        let bottomHeight: CGFloat = 62
        let inputHeight = min(110, max(56, bounds.height * 0.22))
        bottom.frame = NSRect(x: 0, y: bounds.height - bottomHeight, width: bounds.width, height: bottomHeight)
        inputScroll.frame = NSRect(x: pad, y: bottom.frame.minY - inputHeight - pad, width: bounds.width - 2 * pad, height: inputHeight)
        formatBar.frame = NSRect(x: pad, y: inputScroll.frame.minY - 28, width: bounds.width - 2 * pad, height: 26)
        transcriptScroll.frame = NSRect(x: pad, y: pad, width: bounds.width - 2 * pad, height: formatBar.frame.minY - pad - 2)
        icon.frame = NSRect(x: 10, y: 7, width: 48, height: 48)
        info.frame = NSRect(x: 68, y: 18, width: max(80, info.preferredWidth), height: 26)
        send.frame = NSRect(x: bottom.bounds.width - 92, y: 14, width: 82, height: 34)
        for scroll in [transcriptScroll, inputScroll] {
            scroll.documentView?.frame.size.width = scroll.contentSize.width
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
    }

    private func loadIcon() {
        icon.image = AvatarCache.image(for: avatarURL) { [weak self] in self?.loadIcon() }
            ?? Icons.symbol("person.crop.square.fill", size: 30, colors: [Theme.aolBlue])
    }

    func update(buddy: Buddy) {
        buddyName = buddy.name
        if avatarURL != buddy.avatarURL {
            avatarURL = buddy.avatarURL
            loadIcon()
        }
    }

    /// Appends a message once. Discord repeats a message in history and in live events.
    @discardableResult
    func append(_ message: DirectMessage) -> Bool {
        guard shownIDs.insert(message.id).inserted else { return false }
        let mine = message.authorID == myID
        appendLine(name: mine ? myName : buddyName, color: mine ? Self.myColor : Self.buddyColor, text: message.text,
                   date: message.date)
        return true
    }

    func appendNotice(_ text: String) {
        let line = NSAttributedString(string: text + "\n", attributes: [
            .font: NSFontManager.shared.convert(Self.bodyFont, toHaveTrait: .italicFontMask),
            .foregroundColor: Theme.mutedText,
        ])
        add(line)
    }

    private func appendLine(name: String, color: NSColor, text: String, date: Date) {
        let line = NSMutableAttributedString(string: name, attributes: [.font: Self.nameFont, .foregroundColor: color])
        line.append(NSAttributedString(string: ": " + text + "\n",
                                       attributes: [.font: Self.bodyFont, .foregroundColor: Theme.text]))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        line.addAttribute(.toolTip, value: formatter.string(from: date), range: NSRange(location: 0, length: line.length))
        add(line)
    }

    private func add(_ line: NSAttributedString) {
        guard let storage = transcript.textStorage else { return }
        let atBottom = transcriptScroll.contentView.bounds.maxY >= transcript.bounds.height - 30
        storage.append(line)
        if atBottom { transcript.scrollToEndOfDocument(nil) }
    }

    private func wrap(_ marker: String) {
        let range = input.selectedRange()
        let selected = (input.string as NSString).substring(with: range)
        input.insertText(marker + selected + marker, replacementRange: range)
        if selected.isEmpty { input.setSelectedRange(NSRange(location: range.location + marker.count, length: 0)) }
        window?.makeFirstResponder(input)
    }

    private func attach(_ files: [DiscordBridge.Attachment]) {
        let total = (pending + files).reduce(0) { $0 + $1.data.count }
        guard total <= IMAttachments.maxBytes else {
            appendNotice("Attachments over 10 MB can't be sent.")
            NSSound.beep()
            return
        }
        pending += files
        window?.makeFirstResponder(input)
    }

    private func sendTapped() {
        let text = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pending.isEmpty else { NSSound.beep(); return }
        onSend?(text, pending)
    }

    func didSend() {
        input.string = ""
        pending = []
    }

    func setBusy(_ busy: Bool) {
        send.isEnabled = !busy
        input.isEditable = !busy
    }
}
