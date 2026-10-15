import AppKit

final class TabStrip: FlippedView {
    var titles: [String] = [] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?

    private func tabRects() -> [NSRect] {
        var x: CGFloat = 8
        return titles.map { title in
            let width = (title as NSString).size(withAttributes: [.font: Theme.ui(12, bold: true)]).width + 30
            defer { x += width + 3 }
            return NSRect(x: x, y: 5, width: width, height: bounds.height - 5)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        Theme.chromeShade.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        for (i, rect) in tabRects().enumerated() {
            let isSelected = i == selected
            let path = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 8),
                                    xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: rect.minX - 1, y: rect.minY - 1, width: rect.width + 2,
                                      height: rect.height + (isSelected ? 1 : 0))).addClip()
            if isSelected {
                NSColor.white.setFill()
                path.fill()
            } else {
                Theme.gradient([Theme.rgb(250, 248, 240), Theme.rgb(222, 217, 198)], in: path)
            }
            Theme.chromeShade.setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
            drawText(titles[i], font: Theme.ui(12, bold: isSelected), color: isSelected ? Theme.aolBlue : Theme.text,
                     in: rect, align: .center)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = tabRects().firstIndex(where: { $0.contains(p) }), i != selected {
            selected = i
            onSelect?(i)
        }
    }
}

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
        Theme.gradient(Theme.toolbar, in: bounds)
        Theme.chromeShade.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

final class MailboxView: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    enum Action { case read, write, reply, forward, keepAsNew, delete, refresh, connect, webGmail }

    let mail: MailService
    var onAction: ((Action, MailSummary?) -> Void)?
    var onOpen: ((MailSummary) -> Void)?

    private let tabs = TabStrip()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let bar = ButtonBar()
    private let connectPanel = FlippedView()
    private let connectLabel = NSTextField(wrappingLabelWithString: "")
    private var box: MailService.Box = .new
    private var rows: [MailSummary] = []
    private var buttons: [Action: ChromeButton] = [:]

    var selectedSummary: MailSummary? {
        let row = table.selectedRow
        return row >= 0 && row < rows.count ? rows[row] : nil
    }

    init(mail: MailService) {
        self.mail = mail
        super.init(frame: .zero)

        tabs.onSelect = { [weak self] i in
            guard let self else { return }
            self.box = MailService.Box(rawValue: i) ?? .new
            self.reload()
        }

        for (id, title, width) in [("flag", "", 26.0), ("date", "Date", 84.0), ("who", "From", 220.0), ("subject", "Subject", 420.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "flag" ? 26 : 60
            if id == "flag" { column.maxWidth = 26 }
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let specs: [(Action, String, String?)] = [
            (.read, "Read", "envelope.open"), (.write, "Write", "square.and.pencil"),
            (.reply, "Reply", "arrowshape.turn.up.left"), (.forward, "Forward", "arrowshape.turn.up.right"),
            (.keepAsNew, "Keep As New", "envelope.badge"), (.delete, "Delete", "trash"),
            (.refresh, "Refresh", "arrow.clockwise"),
        ]
        bar.buttons = specs.map { action, title, symbol in
            let b = ChromeButton(title: title, symbol: symbol)
            b.action = { [weak self] in self?.perform(action) }
            buttons[action] = b
            return b
        }

        connectLabel.font = Theme.ui(13)
        connectLabel.alignment = .center
        let connect = ChromeButton(title: "Connect Gmail", symbol: "person.badge.key.fill", prominent: true) { [weak self] in
            self?.onAction?(.connect, nil)
        }
        let web = ChromeButton(title: "Open Gmail on the Web", symbol: "globe") { [weak self] in
            self?.onAction?(.webGmail, nil)
        }
        connect.identifier = NSUserInterfaceItemIdentifier("connect")
        web.identifier = NSUserInterfaceItemIdentifier("web")
        [connectLabel, connect, web].forEach(connectPanel.addSubview)

        [tabs, scroll, bar, connectPanel].forEach(addSubview)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        tabs.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 32)
        bar.frame = NSRect(x: 0, y: bounds.height - 42, width: bounds.width, height: 42)
        scroll.frame = NSRect(x: 0, y: 32, width: bounds.width, height: max(0, bar.frame.minY - 32))
        connectPanel.frame = scroll.frame
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
    }

    func reload() {
        let selectedUID = selectedSummary?.uid
        rows = mail.summaries(for: box)
        let newCount = mail.summaries(for: .new).count
        tabs.titles = [newCount > 0 ? "New Mail (\(newCount))" : "New Mail", "Old Mail", "Sent Mail"]
        tabs.selected = box.rawValue
        table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("who"))?.title = box == .sent ? "To" : "From"
        table.reloadData()
        if let selectedUID, let i = rows.firstIndex(where: { $0.uid == selectedUID }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }

        let connected = mail.auth.isConnected
        connectPanel.isHidden = connected
        scroll.isHidden = !connected
        connectLabel.stringValue = mail.auth.hasClient
            ? "Gmail is not connected. Sign in with Google to read your mail here."
            : "Gmail is not set up. Add your Google OAuth client ID and secret in Settings, then connect."

        let count = rows.count
        let noun = box == .new ? "new" : (box == .old ? "old" : "sent")
        bar.statusLabel.stringValue = connected ? "\(count) \(noun) message\(count == 1 ? "" : "s").  \(mail.status)" : mail.status
        updateButtons()
    }

    private func updateButtons() {
        let hasSelection = selectedSummary != nil && mail.auth.isConnected
        for action in [Action.read, .reply, .forward, .delete] { buttons[action]?.isEnabled = hasSelection }
        buttons[.keepAsNew]?.isEnabled = hasSelection && box != .sent
        buttons[.write]?.isEnabled = mail.auth.isConnected
        buttons[.refresh]?.isEnabled = mail.auth.isConnected
    }

    private func perform(_ action: Action) {
        if action == .read {
            openSelected()
        } else {
            onAction?(action, selectedSummary)
        }
    }

    @objc private func openSelected() {
        if let s = selectedSummary { onOpen?(s) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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

        let field = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("textCell"), owner: nil) as? NSTextField
            ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = NSUserInterfaceItemIdentifier("textCell")
                f.lineBreakMode = .byTruncatingTail
                f.cell?.truncatesLastVisibleLine = true
                return f
            }()
        field.font = Theme.ui(12, bold: !s.seen && box != .sent)
        switch id {
        case "date": field.stringValue = MailDate.display(s.date)
        case "who": field.stringValue = MailAddress.name(box == .sent ? s.to : s.from)
        default: field.stringValue = s.subject
        }
        return field
    }
}
