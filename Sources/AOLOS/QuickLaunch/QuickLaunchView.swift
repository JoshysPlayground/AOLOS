import AppKit

/// Dims the AOL window behind the Quick Launch box, keeps clicks and scrolling off the pages underneath,
/// and closes the box on a click outside it.
final class QuickLaunchOverlay: FlippedView {
    let panel = QuickLaunchPanel()
    var onDismiss: (() -> Void)?
    private weak var previousResponder: NSResponder?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        addSubview(panel)
        panel.onClose = { [weak self] in self?.dismiss() }
        panel.onResize = { [weak self] in self?.needsLayout = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Centered on the whole AOL window. The box is placed for its tallest size, so the text field stays put
    /// while the list grows and shrinks under it.
    override func layout() {
        super.layout()
        let width = min(QuickLaunchPanel.width, bounds.width - 40)
        let top = max(20, (bounds.height - QuickLaunchPanel.maxHeight) / 2)
        panel.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: top.rounded(),
                             width: width, height: panel.preferredHeight)
    }

    func present() {
        previousResponder = window?.firstResponder
        layoutSubtreeIfNeeded()
        panel.focus()
    }

    func dismiss() {
        guard superview != nil else { return }
        let window = self.window
        removeFromSuperview()
        if let previous = previousResponder as? NSView, previous.window === window {
            window?.makeFirstResponder(previous)
        }
        onDismiss?()
    }

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss() }
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func scrollWheel(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// The box itself: an XP-style title strip, one big text field, the result list and a hint line.
final class QuickLaunchPanel: FlippedView, NSTextFieldDelegate {
    static let width: CGFloat = 580
    static let titleHeight: CGFloat = 24
    static let fieldHeight: CGFloat = 46
    static let footerHeight: CGFloat = 22
    static let maxListHeight = QuickLaunchList.height(forRows: 12, headers: 5)
    static var maxHeight: CGFloat { titleHeight + fieldHeight + maxListHeight + footerHeight + 4 }

    var sources = QuickLaunchSources() { didSet { refresh(keepSelection: true) } }
    /// The web address the typed text would open, from Session.webURL.
    var urlFor: (String) -> URL? = { _ in nil }
    var onPick: ((QuickLaunchItem) -> Void)?
    /// Typed text worth a directory lookup (Discord people beyond the Buddy List), after a short pause.
    var onQuery: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onResize: (() -> Void)?

    let field = NSTextField()
    private let icon = NSImageView()
    private let list = QuickLaunchList()
    private var lookup: DispatchWorkItem?

    var preferredHeight: CGFloat {
        let listHeight = list.preferredHeight
        return Self.titleHeight + Self.fieldHeight + listHeight + Self.footerHeight + 4
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        self.shadow = shadow

        icon.image = Icons.symbol("magnifyingglass", size: 18, colors: [Theme.aolBlue])
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.ui(19)
        field.textColor = Theme.text
        field.placeholderString = "Search the web, go to a site, find a chat room or a buddy"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        list.onHover = { [weak self] i in self?.list.select(i, byUser: true) }
        list.onClick = { [weak self] i in self?.pick(i) }
        [icon, field, list].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        window?.makeFirstResponder(field)
        refresh(keepSelection: false)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let fieldTop = Self.titleHeight
        icon.frame = NSRect(x: 14, y: fieldTop + 11, width: 24, height: 24)
        field.frame = NSRect(x: 46, y: fieldTop + 11, width: w - 60, height: 26)
        list.frame = NSRect(x: 2, y: fieldTop + Self.fieldHeight, width: w - 4, height: list.preferredHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outer = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        Theme.paper.setFill()
        outer.fill()

        NSGraphicsContext.saveGraphicsState()
        outer.addClip()
        let title = NSRect(x: 0, y: 0, width: bounds.width, height: Self.titleHeight)
        Theme.gradient(Theme.titleActive, in: title)
        let caption: [NSAttributedString.Key: Any] = [.font: Theme.caption(12), .foregroundColor: NSColor.white]
        ("Keyword" as NSString).draw(at: NSPoint(x: 28, y: 4), withAttributes: caption)
        Icons.brandOrTriangle(size: 11)?.draw(in: NSRect(x: 8, y: 5, width: 14, height: 14))
        let hint: [NSAttributedString.Key: Any] = [.font: Theme.ui(11), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        let shortcut = "\u{2318}T" as NSString
        let size = shortcut.size(withAttributes: hint)
        shortcut.draw(at: NSPoint(x: bounds.width - size.width - 10, y: 5), withAttributes: hint)

        let line = Theme.toolbarLine
        line.setFill()
        NSRect(x: 0, y: Self.titleHeight + Self.fieldHeight - 1, width: bounds.width, height: 1).fill()

        let footer = NSRect(x: 0, y: bounds.height - Self.footerHeight, width: bounds.width, height: Self.footerHeight)
        Theme.chrome.setFill()
        footer.fill()
        line.setFill()
        NSRect(x: 0, y: footer.minY, width: bounds.width, height: 1).fill()
        let tips: [NSAttributedString.Key: Any] = [.font: Theme.ui(10.5), .foregroundColor: Theme.mutedText]
        ("\u{2191}\u{2193} choose    Return open    Esc close    @ buddies    # rooms    ? search" as NSString)
            .draw(at: NSPoint(x: 12, y: footer.minY + 5), withAttributes: tips)
        NSGraphicsContext.restoreGraphicsState()

        Theme.frameActive.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        border.lineWidth = 2
        border.stroke()
    }

    // MARK: Results

    private var text: String { field.stringValue }

    /// Rebuilds the list for the current text. When people or rooms arrive late, a row the user arrowed to stays picked.
    func refresh(keepSelection: Bool) {
        let items = QuickLaunch.results(for: text, in: sources, url: urlFor(QuickLaunchScope.parse(text).query))
        let previous = keepSelection && list.userSelected ? list.selectedItem : nil
        list.items = items
        if let previous, let i = items.firstIndex(of: previous) {
            list.select(i, byUser: true)
        } else {
            list.select(QuickLaunch.defaultIndex(items), byUser: false)
        }
        let before = frame.height
        needsLayout = true
        needsDisplay = true
        if before != preferredHeight { onResize?() }
    }

    private func pick(_ index: Int?) {
        guard let index, list.items.indices.contains(index) else { NSSound.beep(); return }
        let item = list.items[index]
        onClose?()
        onPick?(item)
    }

    func controlTextDidChange(_ obj: Notification) {
        refresh(keepSelection: false)
        lookup?.cancel()
        let (scope, query) = QuickLaunchScope.parse(text)
        guard query.count >= 2, scope == .all || scope == .people else { return }
        let work = DispatchWorkItem { [weak self] in self?.onQuery?(query) }
        lookup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            list.move(by: 1)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            list.move(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            pick(list.selected)
        case #selector(NSResponder.cancelOperation(_:)):
            if text.isEmpty { onClose?() } else { field.stringValue = ""; refresh(keepSelection: false) }
        default:
            return false
        }
        return true
    }
}

/// The drawn result rows with section headers. Rows are plain drawing, so hover and selection stay cheap.
final class QuickLaunchList: FlippedView {
    static let rowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 20

    static func height(forRows rows: Int, headers: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(headers) * headerHeight + 6
    }

    var items: [QuickLaunchItem] = [] { didSet { layoutRows() } }
    private(set) var selected: Int?
    /// True once the user has arrowed or pointed at a row, so late results do not steal the selection.
    private(set) var userSelected = false
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    private enum Row { case header(String), item(Int) }
    private var rows: [(row: Row, rect: NSRect)] = []
    private var tracking: NSTrackingArea?

    var selectedItem: QuickLaunchItem? { selected.flatMap { items.indices.contains($0) ? items[$0] : nil } }

    var preferredHeight: CGFloat {
        guard !items.isEmpty else { return 0 }
        return min(rows.last.map { $0.rect.maxY + 6 } ?? 0, QuickLaunchPanel.maxListHeight)
    }

    private func layoutRows() {
        rows = []
        var y: CGFloat = 3
        var section: QuickLaunchItem.Section?
        for (i, item) in items.enumerated() {
            if item.section != section {
                section = item.section
                rows.append((.header(item.section.title), NSRect(x: 0, y: y, width: 0, height: Self.headerHeight)))
                y += Self.headerHeight
            }
            rows.append((.item(i), NSRect(x: 0, y: y, width: 0, height: Self.rowHeight)))
            y += Self.rowHeight
        }
        needsDisplay = true
    }

    func select(_ index: Int?, byUser: Bool) {
        if byUser { userSelected = true } else { userSelected = false }
        guard selected != index else { return }
        selected = index
        needsDisplay = true
    }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = selected ?? (delta > 0 ? -1 : items.count)
        select((current + delta + items.count) % items.count, byUser: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        for (row, rect) in rows where p.y >= rect.minY && p.y < rect.maxY {
            if case .item(let i) = row { return i }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = index(at: event), i != selected { onHover?(i) }
    }

    override func mouseDown(with event: NSEvent) {
        if let i = index(at: event) { onClick?(i) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width
        for (row, frame) in rows {
            let rect = NSRect(x: 0, y: frame.minY, width: width, height: frame.height)
            guard rect.intersects(dirtyRect) else { continue }
            switch row {
            case .header(let title):
                let attrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(10.5, bold: true), .foregroundColor: Theme.aolBlue]
                (title.uppercased() as NSString).draw(at: NSPoint(x: 14, y: rect.minY + 5), withAttributes: attrs)
            case .item(let i):
                drawItem(items[i], in: rect, selected: i == selected)
            }
        }
    }

    private func drawItem(_ item: QuickLaunchItem, in rect: NSRect, selected: Bool) {
        if selected {
            let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 1), xRadius: 4, yRadius: 4)
            Theme.gradient([Theme.rgb(61, 125, 220), Theme.hover], in: highlight)
        }
        let textColor = selected ? NSColor.white : Theme.text
        let mutedColor = selected ? NSColor.white.withAlphaComponent(0.8) : Theme.mutedText

        let (symbol, tint) = Self.icon(for: item)
        Icons.symbol(symbol, size: 14, colors: [selected ? .white : tint])?
            .draw(in: NSRect(x: 16, y: rect.minY + 8, width: 16, height: 16))

        var right = rect.maxX - 14
        if let kind = Self.service(of: item) {
            right = drawBadge(kind, rightEdge: right, midY: rect.midY, selected: selected) - 8
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(13.5), .foregroundColor: textColor]
        let title = item.title as NSString
        let titleWidth = min(title.size(withAttributes: titleAttrs).width, right - 42)
        title.draw(with: NSRect(x: 42, y: rect.minY + 8, width: titleWidth, height: 18),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttrs)
        if !item.subtitle.isEmpty, right - (42 + titleWidth + 10) > 30 {
            let subAttrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(11.5), .foregroundColor: mutedColor]
            let x = 42 + titleWidth + 10
            (item.subtitle as NSString).draw(with: NSRect(x: x, y: rect.minY + 9.5, width: right - x, height: 16),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: subAttrs)
        }
    }

    /// A small colored service tag, like the Buddy List's. Returns its left edge.
    private func drawBadge(_ kind: ChatServiceKind, rightEdge: CGFloat, midY: CGFloat, selected: Bool) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(10, bold: true), .foregroundColor: NSColor.white]
        let name = kind.name as NSString
        let size = name.size(withAttributes: attrs)
        let pill = NSRect(x: rightEdge - size.width - 12, y: midY - 8, width: size.width + 12, height: 16)
        kind.color.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        if selected {
            NSColor.white.withAlphaComponent(0.7).setStroke()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).stroke()
        }
        name.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 1.5), withAttributes: attrs)
        return pill.minX
    }

    private static func service(of item: QuickLaunchItem) -> ChatServiceKind? {
        switch item.action {
        case .person(let buddy): return ChatServiceKind(id: buddy.id)
        case .room(let room): return ChatServiceKind(id: room.id)
        default: return nil
        }
    }

    private static func icon(for item: QuickLaunchItem) -> (String, NSColor) {
        switch item.action {
        case .website: return ("globe", Theme.aolBlue)
        case .search: return ("magnifyingglass", Theme.aolBlue)
        case .keyword: return ("arrow.right.circle.fill", Theme.rgb(232, 168, 0))
        case .room(let room): return (room.voice ? "speaker.wave.2.fill" : "number", Theme.aolBlue)
        case .person(let buddy):
            switch buddy.presence {
            case .online: return ("person.fill", Theme.rgb(40, 160, 70))
            case .idle: return ("person.fill", Theme.rgb(220, 160, 0))
            case .dnd: return ("person.fill", Theme.rgb(200, 50, 40))
            case .offline: return ("person.fill", Theme.rgb(150, 150, 150))
            }
        }
    }
}
