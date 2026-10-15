import AppKit
import WebKit

/// Bottom row of ChromeButtons with optional status text on the right.
final class ButtonBar: FlippedView {
    var buttons: [ChromeButton] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            buttons.forEach(addSubview)
            needsLayout = true
        }
    }
    let statusLabel = NSTextField(labelWithString: "")
    var colors = Theme.toolbar { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        statusLabel.font = Theme.ui(11)
        statusLabel.textColor = Theme.mutedText
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        var x: CGFloat = 8
        for b in buttons {
            let w = max(64, b.preferredWidth)
            b.frame = NSRect(x: x, y: (bounds.height - 26) / 2, width: w, height: 26)
            x += w + 6
        }
        statusLabel.frame = NSRect(x: x + 10, y: (bounds.height - 16) / 2, width: max(0, bounds.width - x - 20), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(colors, in: bounds)
        Theme.toolbarLine.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// Sends the Delete key to the mailbox instead of beeping.
final class MailTableView: NSTableView {
    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            onDeleteKey?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The blue Mailbox header: tabs on the left, Mail Options and Help on the right.
final class MailHeaderBar: FlippedView {
    var titles: [String] = [] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onMenu: ((Int, NSPoint) -> Void)?
    let menuTitles = ["Mail Options", "Help"]

    private func tabRects() -> [NSRect] {
        var x: CGFloat = 8
        return titles.map { title in
            let width = (title as NSString).size(withAttributes: [.font: Theme.ui(12, bold: true)]).width + 26
            defer { x += width + 2 }
            return NSRect(x: x, y: 6, width: width, height: bounds.height - 6)
        }
    }

    private func menuRects() -> [NSRect] {
        var x = bounds.width - 10
        return menuTitles.reversed().map { title -> NSRect in
            let width = (title as NSString).size(withAttributes: [.font: Theme.ui(11, bold: true)]).width + 16
            x -= width
            defer { x -= 12 }
            return NSRect(x: x, y: 0, width: width, height: bounds.height)
        }.reversed()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient([Theme.rgb(74, 138, 222), Theme.rgb(30, 88, 184)], in: bounds)
        Theme.rgb(18, 58, 140).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        for (i, rect) in tabRects().enumerated() {
            let isSelected = i == selected
            let path = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 8),
                                    xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: rect.minX - 1, y: rect.minY - 1, width: rect.width + 2,
                                      height: rect.height + (isSelected ? 1 : 0))).addClip()
            Theme.gradient(isSelected ? [.white, Theme.rgb(232, 241, 253)]
                                      : [Theme.rgb(208, 226, 250), Theme.rgb(150, 186, 236)], in: path)
            Theme.rgb(20, 62, 150).setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
            drawText(titles[i], font: Theme.ui(12, bold: true), color: isSelected ? Theme.rgb(0, 40, 130) : Theme.rgb(20, 50, 110),
                     in: rect, align: .center)
        }

        for (title, rect) in zip(menuTitles, menuRects()) {
            drawText(title, font: Theme.ui(11, bold: true), color: .white,
                     in: NSRect(x: rect.minX, y: rect.minY, width: rect.width - 10, height: rect.height))
            let arrow = NSBezierPath()
            let ax = rect.maxX - 8, ay = rect.midY - 1
            arrow.move(to: NSPoint(x: ax - 3.5, y: ay - 2))
            arrow.line(to: NSPoint(x: ax + 3.5, y: ay - 2))
            arrow.line(to: NSPoint(x: ax, y: ay + 2.5))
            arrow.close()
            NSColor.white.setFill()
            arrow.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = tabRects().firstIndex(where: { $0.contains(p) }) {
            selected = i
            onSelect?(i)
        } else if let i = menuRects().firstIndex(where: { $0.contains(p) }) {
            onMenu?(i, NSPoint(x: menuRects()[i].minX, y: bounds.height))
        }
    }
}

/// The preview under the message list. Scripts never run and remote images stay blocked.
final class QuickReadView: FlippedView, WKNavigationDelegate {
    var onFullView: (() -> Void)?
    var onQuickReply: (() -> Void)?
    var onOpenLink: ((URL) -> Void)?

    private let webView: WKWebView
    private let fullView = ChromeButton(title: "Full View", symbol: "arrow.up.left.and.arrow.down.right")
    private let quickReply = ChromeButton(title: "Quick Reply", symbol: "arrowshape.turn.up.left")
    private var from = ""
    private var subject = ""
    private var placeholder = "Select a message to read it here."

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)
        webView.navigationDelegate = self
        fullView.action = { [weak self] in self?.onFullView?() }
        quickReply.action = { [weak self] in self?.onQuickReply?() }
        [webView, fullView, quickReply].forEach(addSubview)
        clear("Select a message to read it here.")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let qw = quickReply.preferredWidth + 6, fw = fullView.preferredWidth + 6
        quickReply.frame = NSRect(x: bounds.width - qw - 8, y: 3, width: qw, height: 22)
        fullView.frame = NSRect(x: quickReply.frame.minX - fw - 6, y: 3, width: fw, height: 22)
        webView.frame = NSRect(x: 1, y: 64, width: bounds.width - 2, height: max(0, bounds.height - 65))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        Theme.gradient([Theme.rgb(226, 237, 252), Theme.rgb(190, 212, 242)], in: NSRect(x: 0, y: 0, width: bounds.width, height: 28))
        Theme.toolbarLine.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: 28, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: 63, width: bounds.width, height: 1).fill()
        drawText("Quick Read", font: Theme.ui(12, bold: true), color: Theme.rgb(0, 40, 130),
                 in: NSRect(x: 10, y: 0, width: 160, height: 28))
        if from.isEmpty {
            drawText(placeholder, font: Theme.ui(12), color: Theme.mutedText,
                     in: NSRect(x: 12, y: 36, width: bounds.width - 24, height: 20))
        } else {
            drawText("From:", font: Theme.ui(11, bold: true), color: Theme.mutedText, in: NSRect(x: 10, y: 31, width: 56, height: 16), align: .right)
            drawText(from, font: Theme.ui(12), color: Theme.text, in: NSRect(x: 72, y: 31, width: bounds.width - 84, height: 16))
            drawText("Subject:", font: Theme.ui(11, bold: true), color: Theme.mutedText, in: NSRect(x: 10, y: 46, width: 56, height: 16), align: .right)
            drawText(subject, font: Theme.ui(12, bold: true), color: Theme.text, in: NSRect(x: 72, y: 46, width: bounds.width - 84, height: 16))
        }
    }

    func show(_ message: MailMessage) {
        from = message.from
        subject = message.subject
        fullView.isEnabled = true
        quickReply.isEnabled = true
        webView.isHidden = false
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if let rules = RemoteContentBlocker.ruleList { controller.add(rules) }
        webView.loadHTMLString(message.html, baseURL: nil)
        needsDisplay = true
    }

    func clear(_ text: String) {
        from = ""
        subject = ""
        placeholder = text
        fullView.isEnabled = false
        quickReply.isEnabled = false
        webView.isHidden = true
        webView.loadHTMLString("", baseURL: nil)
        needsDisplay = true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            decisionHandler(.cancel)
            if url.scheme == "http" || url.scheme == "https" { onOpenLink?(url) }
            return
        }
        decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }
}

/// The AOL 9 Mailbox: tabs, a mail folder tree, the message list, Quick Read, and the action row.
final class MailboxView: FlippedView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    enum Action { case read, write, reply, forward, markRead, keepAsNew, reportSpam, delete, refresh, connect, webGmail }

    enum Source: Equatable {
        case box(MailService.Box)
        case folder(String)
        case search
    }

    enum Filter: Int, CaseIterable {
        case everyone, unread, read

        var title: String {
            switch self {
            case .everyone: return "Everyone"
            case .unread: return "Unread mail"
            case .read: return "Read mail"
            }
        }
    }

    private enum FolderRow {
        case heading(String)
        case box(MailService.Box)
        case label(MailFolderInfo)
    }

    let mail: MailService
    var onAction: ((Action, [MailSummary]) -> Void)?
    var onOpen: ((MailSummary) -> Void)?
    var onOpenLink: ((URL) -> Void)?

    private let header = MailHeaderBar()
    private let filterStrip = FlippedView()
    private let showPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let showLabel = NSTextField(labelWithString: "Show mail from:")
    private let findLabel = NSTextField(labelWithString: "Quick find:")
    private let findField = NSSearchField()
    private let folderTable = NSTableView()
    private let folderScroll = NSScrollView()
    private let folderTitle = GradientView(colors: [Theme.rgb(226, 237, 252), Theme.rgb(190, 212, 242)])
    private let split = NSSplitView()
    private let table = MailTableView()
    private let scroll = NSScrollView()
    private let quickRead = QuickReadView()
    private let bar = ButtonBar()
    private let connectPanel = FlippedView()
    private let connectLabel = NSTextField(wrappingLabelWithString: "")
    private var source: Source = .box(.new)
    private var filter: Filter = .everyone
    private var rows: [MailSummary] = []
    private var folderRows: [FolderRow] = []
    private var buttons: [Action: ChromeButton] = [:]
    private var previewKey: String?
    private var previewTask: Task<Void, Never>?
    private var loadingFolder: String?
    private var searchError: String?
    private var didPlaceSplit = false

    var selectedSummaries: [MailSummary] {
        table.selectedRowIndexes.filter { $0 < rows.count }.map { rows[$0] }
    }

    init(mail: MailService) {
        self.mail = mail
        super.init(frame: .zero)

        header.titles = ["New", "Old", "Sent", "Manage Mail", "Search Mail"]
        header.onSelect = { [weak self] i in self?.selectTab(i) }
        header.onMenu = { [weak self] i, point in self?.showHeaderMenu(i, at: point) }

        [showLabel, findLabel].forEach {
            $0.font = Theme.ui(11, bold: true)
            $0.textColor = Theme.rgb(0, 40, 130)
        }
        showPopup.addItems(withTitles: Filter.allCases.map(\.title))
        showPopup.controlSize = .small
        showPopup.font = Theme.ui(11)
        showPopup.target = self
        showPopup.action = #selector(filterChosen)
        findField.controlSize = .small
        findField.font = Theme.ui(11)
        findField.delegate = self
        findField.sendsSearchStringImmediately = false
        findField.sendsWholeSearchString = true
        findField.target = self
        findField.action = #selector(findCommitted)
        [showLabel, showPopup, findLabel, findField].forEach(filterStrip.addSubview)

        let folderLabel = NSTextField(labelWithString: "My Mail Folders")
        folderLabel.font = Theme.ui(12, bold: true)
        folderLabel.textColor = Theme.rgb(0, 40, 130)
        folderLabel.frame = NSRect(x: 8, y: 5, width: 170, height: 18)
        folderTitle.addSubview(folderLabel)
        let folderColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        folderColumn.resizingMask = .autoresizingMask
        folderTable.addTableColumn(folderColumn)
        folderTable.headerView = nil
        folderTable.rowHeight = 20
        folderTable.style = .plain
        folderTable.backgroundColor = Theme.rgb(240, 246, 254)
        folderTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        folderTable.dataSource = self
        folderTable.delegate = self
        folderScroll.documentView = folderTable
        folderScroll.hasVerticalScroller = true
        folderScroll.borderType = .noBorder
        folderScroll.drawsBackground = false

        for (id, title, width) in [("flag", "", 26.0), ("date", "Date", 84.0), ("who", "Name", 200.0), ("subject", "Subject", 400.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "flag" ? 26 : 60
            if id == "flag" { column.maxWidth = 26 }
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.allowsMultipleSelection = true
        table.onDeleteKey = { [weak self] in self?.perform(.delete) }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        quickRead.onFullView = { [weak self] in self?.openSelected() }
        quickRead.onQuickReply = { [weak self] in self?.perform(.reply) }
        quickRead.onOpenLink = { [weak self] url in self?.onOpenLink?(url) }
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(quickRead)

        let specs: [(Action, String, String)] = [
            (.read, "Read", "envelope.open"), (.reply, "Reply", "arrowshape.turn.up.left"),
            (.forward, "Forward", "arrowshape.turn.up.right"), (.keepAsNew, "Keep As New", "envelope.badge"),
            (.markRead, "Mark as Read", "envelope.open.fill"), (.reportSpam, "Report Spam", "hand.raised.fill"),
            (.delete, "Delete", "trash"),
        ]
        bar.colors = [Theme.rgb(232, 241, 253), Theme.rgb(200, 219, 245)]
        bar.buttons = specs.map { action, title, symbol in
            let b = ChromeButton(title: title, symbol: symbol)
            b.action = { [weak self] in self?.perform(action) }
            buttons[action] = b
            return b
        }

        connectLabel.font = Theme.ui(13)
        connectLabel.alignment = .center
        let connect = ChromeButton(title: "Connect Gmail", symbol: "person.badge.key.fill", prominent: true) { [weak self] in
            self?.onAction?(.connect, [])
        }
        let web = ChromeButton(title: "Open Gmail on the Web", symbol: "globe") { [weak self] in
            self?.onAction?(.webGmail, [])
        }
        connect.identifier = NSUserInterfaceItemIdentifier("connect")
        web.identifier = NSUserInterfaceItemIdentifier("web")
        [connectLabel, connect, web].forEach(connectPanel.addSubview)

        [header, filterStrip, folderTitle, folderScroll, split, bar, connectPanel].forEach(addSubview)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 32)
        filterStrip.frame = NSRect(x: 0, y: 32, width: bounds.width, height: 32)
        showLabel.frame = NSRect(x: 10, y: 8, width: 100, height: 16)
        showPopup.frame = NSRect(x: 108, y: 5, width: 130, height: 22)
        let fw = min(260, max(120, bounds.width - 420))
        findField.frame = NSRect(x: bounds.width - fw - 10, y: 6, width: fw, height: 20)
        findLabel.frame = NSRect(x: findField.frame.minX - 76, y: 8, width: 72, height: 16)

        bar.frame = NSRect(x: 0, y: bounds.height - 40, width: bounds.width, height: 40)
        let top: CGFloat = 64
        let height = max(0, bar.frame.minY - top)
        let folderWidth: CGFloat = bounds.width > 700 ? 180 : 0
        folderTitle.isHidden = folderWidth == 0
        folderScroll.isHidden = folderWidth == 0
        folderTitle.frame = NSRect(x: 0, y: top, width: folderWidth, height: 28)
        folderScroll.frame = NSRect(x: 0, y: top + 28, width: folderWidth, height: max(0, height - 28))
        let mainX = folderWidth == 0 ? 0 : folderWidth + 1
        split.frame = NSRect(x: mainX, y: top, width: bounds.width - mainX, height: height)
        if !didPlaceSplit, height > 200 {
            didPlaceSplit = true
            split.setPosition(floor(height * 0.48), ofDividerAt: 0)
        }
        split.adjustSubviews()

        connectPanel.frame = split.frame
        let w = min(460, connectPanel.bounds.width - 40)
        let x = (connectPanel.bounds.width - w) / 2
        connectLabel.frame = NSRect(x: x, y: 60, width: w, height: 60)
        for v in connectPanel.subviews {
            guard let b = v as? ChromeButton else { continue }
            let bw = b.preferredWidth + 10
            let y: CGFloat = b.identifier?.rawValue == "connect" ? 136 : 172
            b.frame = NSRect(x: (connectPanel.bounds.width - bw) / 2, y: y, width: bw, height: 28)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        Theme.gradient([Theme.rgb(246, 250, 255), Theme.rgb(222, 234, 250)], in: filterStrip.frame)
        Theme.toolbarLine.setFill()
        NSRect(x: 0, y: filterStrip.frame.maxY - 1, width: bounds.width, height: 1).fill()
        if !folderScroll.isHidden {
            Theme.rgb(240, 246, 254).setFill()
            NSRect(x: 0, y: folderTitle.frame.maxY, width: folderScroll.frame.width, height: folderScroll.frame.height).fill()
            Theme.toolbarLine.setFill()
            NSRect(x: folderScroll.frame.maxX, y: folderTitle.frame.minY, width: 1, height: folderTitle.frame.height + folderScroll.frame.height).fill()
            NSRect(x: 0, y: folderTitle.frame.maxY - 1, width: folderScroll.frame.width, height: 1).fill()
        }
    }

    func reload() {
        let selectedKeys = Set(selectedSummaries.map(Self.key))
        let newCount = mail.summaries(for: .new).count
        header.titles = [newCount > 0 ? "New (\(newCount))" : "New", "Old", "Sent", "Manage Mail", "Search Mail"]
        header.selected = tabIndex
        findField.placeholderString = source == .search ? "Search all mail, then press Return" : "Name or subject"

        rows = filtered(baseRows())
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("who"))?.title = showsRecipient ? "Sent To" : "Name"
        table.reloadData()
        let keep = IndexSet(rows.indices.filter { selectedKeys.contains(Self.key(rows[$0])) })
        table.selectRowIndexes(keep, byExtendingSelection: false)

        folderRows = [.heading("Mailbox"), .box(.new), .box(.old), .box(.sent)]
        let labels = mail.folders.list.filter { $0.name != "INBOX" && $0.name != mail.folders.sent }
        if !labels.isEmpty { folderRows.append(.heading("Gmail Folders")) }
        folderRows += labels.map(FolderRow.label)
        folderTable.reloadData()
        if let i = folderRows.firstIndex(where: { isCurrent($0) }) {
            folderTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        } else {
            folderTable.deselectAll(nil)
        }

        let connected = mail.auth.isConnected
        connectPanel.isHidden = connected
        split.isHidden = !connected
        connectLabel.stringValue = mail.auth.hasClient
            ? "Gmail is not connected. Sign in with Google to read your mail here."
            : "This build has no Google OAuth client. Add one in Settings, then connect."

        updateButtons()
        updatePreview()
    }

    private static func key(_ s: MailSummary) -> String { "\(s.folder)/\(s.uid)" }

    private var tabIndex: Int {
        switch source {
        case .box(let box): return box.rawValue
        case .folder: return 3
        case .search: return 4
        }
    }

    private var showsRecipient: Bool {
        switch source {
        case .box(let box): return box == .sent
        case .folder(let name): return name == mail.folders.sent
        case .search: return false
        }
    }

    private func isCurrent(_ row: FolderRow) -> Bool {
        switch (row, source) {
        case (.box(let a), .box(let b)): return a == b
        case (.label(let info), .folder(let name)): return info.name == name
        default: return false
        }
    }

    private func baseRows() -> [MailSummary] {
        switch source {
        case .box(let box): return mail.summaries(for: box)
        case .folder(let name): return mail.folderMessages[name] ?? []
        case .search: return mail.searchResults
        }
    }

    private func filtered(_ list: [MailSummary]) -> [MailSummary] {
        var out = list
        switch filter {
        case .everyone: break
        case .unread: out = out.filter { !$0.seen }
        case .read: out = out.filter(\.seen)
        }
        let q = findField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty, source != .search {
            out = out.filter { "\($0.from) \($0.to) \($0.subject)".lowercased().contains(q) }
        }
        return out
    }

    private func selectTab(_ i: Int) {
        switch i {
        case 0, 1, 2: show(.box(MailService.Box(rawValue: i) ?? .new))
        case 3:
            let first = mail.folders.list.first { $0.name != "INBOX" && $0.name != mail.folders.sent }
            if let first { show(.folder(first.name)) } else { header.selected = tabIndex }
        default:
            show(.search)
            window?.makeFirstResponder(findField)
        }
    }

    private func show(_ newSource: Source) {
        guard newSource != source else { return }
        let leavingSearch = source == .search
        source = newSource
        searchError = nil
        if newSource == .search {
            findField.stringValue = mail.lastSearch
        } else if leavingSearch {
            findField.stringValue = ""
        }
        if case .folder(let name) = newSource, mail.folderMessages[name] == nil { load(name) }
        reload()
    }

    private func load(_ folder: String) {
        loadingFolder = folder
        updateButtons()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.mail.loadFolder(folder)
            } catch {
                self.searchError = error.localizedDescription
            }
            if self.loadingFolder == folder { self.loadingFolder = nil }
            self.reload()
        }
    }

    private func showHeaderMenu(_ index: Int, at point: NSPoint) {
        let menu = NSMenu()
        if index == 0 {
            menu.addItem(ActionItem("Write Mail") { [weak self] in self?.onAction?(.write, []) })
            menu.addItem(ActionItem("Check Mail Now") { [weak self] in self?.onAction?(.refresh, []) })
            let unread = mail.summaries(for: .new)
            let markAll = ActionItem("Mark All New Mail as Read") { [weak self] in self?.onAction?(.markRead, unread) }
            markAll.isEnabled = !unread.isEmpty
            menu.addItem(markAll)
            menu.addItem(.separator())
            menu.addItem(ActionItem("Open Gmail on the Web") { [weak self] in self?.onAction?(.webGmail, []) })
        } else {
            menu.addItem(ActionItem("Search Mail Tips") { [weak self] in
                self?.onOpenLink?(URL(string: "https://support.google.com/mail/answer/7190")!)
            })
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: point, in: header)
    }

    @objc private func filterChosen() {
        filter = Filter(rawValue: showPopup.indexOfSelectedItem) ?? .everyone
        reload()
    }

    func controlTextDidChange(_ obj: Notification) {
        if source != .search { reload() }
    }

    @objc private func findCommitted() {
        guard source == .search else { return }
        let query = findField.stringValue
        searchError = nil
        loadingFolder = "search"
        updateButtons()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.mail.search(query)
            } catch {
                self.searchError = error.localizedDescription
            }
            self.loadingFolder = nil
            self.reload()
        }
    }

    private func enabled(_ action: Action, for selection: [MailSummary]) -> Bool {
        guard mail.auth.isConnected else { return false }
        switch action {
        case .write, .refresh, .connect, .webGmail: return true
        case .read, .delete: return !selection.isEmpty
        case .reply, .forward: return selection.count == 1
        case .markRead: return selection.contains { !$0.seen }
        case .keepAsNew: return !showsRecipient && selection.contains { $0.seen }
        case .reportSpam: return !showsRecipient && !selection.isEmpty && !selection.contains { $0.folder == mail.folders.junk }
        }
    }

    private func updateButtons() {
        let selection = selectedSummaries
        for (action, button) in buttons { button.isEnabled = enabled(action, for: selection) }
        var status: String
        if loadingFolder != nil {
            status = source == .search ? "Searching..." : "Loading folder..."
        } else if let searchError {
            status = searchError
        } else if source == .search, mail.lastSearch.isEmpty {
            status = "Type a search and press Return."
        } else {
            let count = rows.count
            status = "\(count) message\(count == 1 ? "" : "s")"
            if selection.count > 1 { status += ", \(selection.count) selected" }
        }
        bar.statusLabel.stringValue = mail.auth.isConnected ? status : mail.status
    }

    private func updatePreview() {
        let selection = selectedSummaries
        guard selection.count == 1, let summary = selection.first else {
            previewTask?.cancel()
            previewKey = nil
            quickRead.clear(selection.isEmpty ? "Select a message to read it here." : "\(selection.count) messages selected.")
            return
        }
        let key = Self.key(summary)
        guard key != previewKey else { return }
        previewKey = key
        previewTask?.cancel()
        quickRead.clear("Loading message...")
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled, self.previewKey == key else { return }
            do {
                let message = try await self.mail.message(summary, markSeen: false)
                guard self.previewKey == key else { return }
                self.quickRead.show(message)
            } catch {
                guard self.previewKey == key else { return }
                self.quickRead.clear(error.localizedDescription)
            }
        }
    }

    private func perform(_ action: Action) {
        let selection = selectedSummaries
        guard enabled(action, for: selection) else { return }
        if action == .read {
            openSelected()
        } else {
            onAction?(action, selection)
        }
    }

    /// Opens up to five selected messages so a large selection does not flood the desktop.
    @objc private func openSelected() {
        for summary in selectedSummaries.prefix(5) { onOpen?(summary) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
            table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        let selection = selectedSummaries
        let entries: [(Action, String)] = [
            (.read, "Read"), (.reply, "Reply"), (.forward, "Forward"),
            (.markRead, "Mark as Read"), (.keepAsNew, "Keep As New"), (.reportSpam, "Report Spam"), (.delete, "Delete"),
        ]
        for (action, title) in entries {
            if action == .markRead || action == .reportSpam { menu.addItem(.separator()) }
            let item = ActionItem(title) { [weak self] in self?.perform(action) }
            item.isEnabled = enabled(action, for: selection)
            menu.addItem(item)
        }
        menu.autoenablesItems = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === folderTable ? folderRows.count : rows.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === folderTable, row < folderRows.count else { return true }
        if case .heading = folderRows[row] { return false }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === folderTable {
            let row = folderTable.selectedRow
            guard row >= 0, row < folderRows.count else { return }
            switch folderRows[row] {
            case .heading: break
            case .box(let box): show(.box(box))
            case .label(let info): show(.folder(info.name))
            }
            return
        }
        updateButtons()
        updatePreview()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === folderTable { return folderCell(row) }
        guard row < rows.count else { return nil }
        let s = rows[row]
        let id = tableColumn?.identifier.rawValue ?? ""

        if id == "flag" {
            let image = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("flagCell"), owner: nil) as? NSImageView
                ?? {
                    let v = NSImageView()
                    v.identifier = NSUserInterfaceItemIdentifier("flagCell")
                    return v
                }()
            image.image = Icons.symbol(s.seen ? "envelope.open" : "envelope.fill", size: 12,
                                       colors: [s.seen ? Theme.mutedText : Theme.aolBlue])
            return image
        }

        let field = textCell(tableView, id: "textCell")
        field.font = Theme.ui(12, bold: !s.seen && !showsRecipient)
        switch id {
        case "date": field.stringValue = MailDate.display(s.date)
        case "who": field.stringValue = MailAddress.name(showsRecipient ? s.to : s.from)
        default: field.stringValue = s.subject
        }
        return field
    }

    private func textCell(_ tableView: NSTableView, id: String) -> NSTextField {
        tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id), owner: nil) as? NSTextField
            ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = NSUserInterfaceItemIdentifier(id)
                f.lineBreakMode = .byTruncatingTail
                f.cell?.truncatesLastVisibleLine = true
                return f
            }()
    }

    private func folderCell(_ row: Int) -> NSView? {
        guard row < folderRows.count else { return nil }
        let cell = folderTable.makeView(withIdentifier: NSUserInterfaceItemIdentifier("folderCell"), owner: nil) as? FolderCell
            ?? FolderCell()
        cell.identifier = NSUserInterfaceItemIdentifier("folderCell")
        switch folderRows[row] {
        case .heading(let title):
            cell.configure(title: title, symbol: nil, indent: 0, bold: true, heading: true)
        case .box(let box):
            let unread = mail.summaries(for: .new).count
            switch box {
            case .new: cell.configure(title: unread > 0 ? "New Mail (\(unread))" : "New Mail", symbol: "envelope.fill", indent: 1, bold: unread > 0)
            case .old: cell.configure(title: "Old Mail", symbol: "envelope.open", indent: 1)
            case .sent: cell.configure(title: "Sent Mail", symbol: "paperplane", indent: 1)
            }
        case .label(let info):
            let symbol: String
            switch info.name {
            case mail.folders.trash: symbol = "trash"
            case mail.folders.junk: symbol = "hand.raised"
            case mail.folders.allMail: symbol = "tray.full"
            default: symbol = info.attributes.contains("\\drafts") ? "doc.text" : "folder"
            }
            cell.configure(title: info.leafName, symbol: symbol, indent: 1 + info.depth)
        }
        return cell
    }
}

private final class FolderCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var indent = 0

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        [icon, label].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, symbol: String?, indent: Int, bold: Bool = false, heading: Bool = false) {
        self.indent = indent
        label.stringValue = title
        label.font = Theme.ui(heading ? 11 : 12, bold: bold)
        label.textColor = heading ? Theme.mutedText : Theme.text
        icon.image = symbol.flatMap { Icons.symbol($0, size: 12, colors: [Theme.aolBlue]) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let x = 6 + CGFloat(indent) * 12
        icon.frame = NSRect(x: x, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let lx = icon.image == nil ? x : x + 19
        label.frame = NSRect(x: lx, y: (bounds.height - 16) / 2, width: max(0, bounds.width - lx - 4), height: 16)
    }
}
