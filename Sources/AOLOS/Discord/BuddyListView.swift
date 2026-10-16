import AppKit

/// Buddy icons from the Discord CDN, loaded once per URL.
@MainActor
enum AvatarCache {
    private static var images: [URL: NSImage] = [:]
    private static var loading: Set<URL> = []

    static func image(for url: URL?, onLoad: @escaping @MainActor () -> Void) -> NSImage? {
        guard let url else { return nil }
        if let image = images[url] { return image }
        guard loading.insert(url).inserted else { return nil }
        Task {
            let data = try? await URLSession.shared.data(from: url).0
            loading.remove(url)
            if let data, let image = NSImage(data: data) {
                images[url] = image
                onLoad()
            }
        }
        return nil
    }
}

/// The AIM-style tree of groups and buddies. Draws its own rows inside a scroll view.
final class BuddyTreeView: FlippedView {
    enum Row {
        case group(String, Int)
        case buddy(Buddy)
        case chat(GroupChat)
    }

    var onOpen: ((Buddy) -> Void)?
    var onOpenChat: ((GroupChat) -> Void)?
    var onMenu: ((Buddy, NSEvent, NSView) -> Void)?
    var onGroupMenu: ((NSEvent, NSView) -> Void)?
    var recentChange: ((String) -> BuddyChange?)?
    private(set) var rows: [Row] = []
    private(set) var selectedID: String?
    private var collapsed: Set<Int> = [3]
    private var buddies: [Buddy] = []
    private var recentBuddies: [Buddy] = []
    private var chats: [GroupChat] = []
    private var selectedChatID: String?
    static let rowHeight: CGFloat = 19

    var selected: Buddy? {
        guard let selectedID else { return nil }
        return buddies.first { $0.id == selectedID } ?? recentBuddies.first { $0.id == selectedID }
    }

    override var acceptsFirstResponder: Bool { true }

    func show(_ buddies: [Buddy], recent: [Buddy], chats: [GroupChat]) {
        self.buddies = buddies
        recentBuddies = recent
        self.chats = chats
        rebuild()
    }

    private func rebuild() {
        let online = buddies.filter { $0.isOnline || recentChange?($0.id) == .signedOff }
        let offline = buddies.filter { !$0.isOnline && recentChange?($0.id) != .signedOff }
        rows = [.group("Recent Buddies (\(recentBuddies.filter(\.isOnline).count)/\(recentBuddies.count))", 0)]
        if !collapsed.contains(0) { rows += recentBuddies.map(Row.buddy) }
        rows.append(.group("Group Chats (\(chats.count))", 1))
        if !collapsed.contains(1) { rows += chats.map(Row.chat) }
        rows.append(.group("Buddies (\(buddies.filter(\.isOnline).count)/\(buddies.count))", 2))
        if !collapsed.contains(2) { rows += online.map(Row.buddy) }
        rows.append(.group("Offline (\(offline.count))", 3))
        if !collapsed.contains(3) { rows += offline.map(Row.buddy) }
        let height = max(CGFloat(rows.count) * Self.rowHeight + 6, enclosingScrollView?.contentSize.height ?? 0)
        setFrameSize(NSSize(width: enclosingScrollView?.contentSize.width ?? bounds.width, height: height))
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        rebuild()
    }

    private func row(at point: NSPoint) -> Int? {
        let i = Int((point.y - 3) / Self.rowHeight)
        return i >= 0 && i < rows.count ? i : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        for (i, row) in rows.enumerated() {
            let rect = NSRect(x: 0, y: 3 + CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
            guard rect.intersects(dirtyRect) else { continue }
            switch row {
            case .group(let title, let index):
                drawToggle(open: !collapsed.contains(index), at: NSPoint(x: 6, y: rect.midY))
                drawText(title, font: Theme.ui(12, bold: true), color: Theme.text,
                         in: NSRect(x: 22, y: rect.minY, width: rect.width - 26, height: rect.height))
            case .buddy(let buddy):
                drawBuddy(buddy, in: rect)
            case .chat(let chat):
                drawChat(chat, in: rect)
            }
        }
    }

    private func drawToggle(open: Bool, at p: NSPoint) {
        let box = NSRect(x: p.x, y: p.y - 5, width: 10, height: 10)
        NSColor.white.setFill()
        box.fill()
        Theme.chromeShade.setStroke()
        NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
        Theme.aolBlue.setFill()
        NSRect(x: box.minX + 2, y: box.midY - 0.75, width: 6, height: 1.5).fill()
        if !open { NSRect(x: box.midX - 0.75, y: box.minY + 2, width: 1.5, height: 6).fill() }
    }

    private func drawChat(_ chat: GroupChat, in rect: NSRect) {
        let isSelected = chat.id == selectedChatID
        if isSelected {
            Theme.hover.setFill()
            NSRect(x: 18, y: rect.minY, width: rect.width - 20, height: rect.height).fill()
        }
        Icons.symbol("person.3.fill", size: 10, colors: [isSelected ? .white : Theme.aolBlue])?
            .draw(in: NSRect(x: 24, y: rect.midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)
        let font = Theme.ui(12)
        let nameWidth = min((chat.name as NSString).size(withAttributes: [.font: font]).width, rect.width - 90)
        drawText(chat.name, font: font, color: isSelected ? .white : Theme.text,
                 in: NSRect(x: 46, y: rect.minY, width: nameWidth + 2, height: rect.height))
        drawText("(\(chat.onlineCount)/\(chat.members.count))", font: Theme.ui(10.5),
                 color: isSelected ? .white : Theme.mutedText,
                 in: NSRect(x: 50 + nameWidth, y: rect.minY, width: max(0, rect.width - nameWidth - 54), height: rect.height))
    }

    private func drawBuddy(_ buddy: Buddy, in rect: NSRect) {
        let isSelected = buddy.id == selectedID
        if isSelected {
            Theme.hover.setFill()
            NSRect(x: 18, y: rect.minY, width: rect.width - 20, height: rect.height).fill()
        }
        let iconRect = NSRect(x: 24, y: rect.midY - 8, width: 16, height: 16)
        let change = recentChange?(buddy.id)
        if let change, change == .signedOn || change == .signedOff {
            let door = Icons.symbol(change == .signedOn ? "door.left.hand.open" : "door.left.hand.closed",
                                    size: 12, colors: [Theme.rgb(150, 90, 30)])
            door?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if let symbol = statusSymbol(buddy) {
            symbol.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if let avatar = AvatarCache.image(for: buddy.avatarURL, onLoad: { [weak self] in self?.needsDisplay = true }) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: iconRect, xRadius: 3, yRadius: 3).addClip()
            avatar.draw(in: iconRect, from: .zero, operation: .sourceOver,
                        fraction: buddy.isOnline ? 1 : 0.45, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            Icons.symbol("person.crop.square.fill", size: 12, colors: [Theme.aolBlue])?
                .draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let idle = buddy.presence == .idle || !buddy.isOnline
        let color: NSColor = isSelected ? .white : (idle ? Theme.rgb(130, 130, 130) : Theme.text)
        let font = change == .signedOn ? Theme.ui(12, bold: true) : Theme.ui(12)
        var name = buddy.name
        if !buddy.activity.isEmpty && buddy.isOnline { name += "  " }
        let nameWidth = min((name as NSString).size(withAttributes: [.font: font]).width, rect.width - 50)
        drawText(name, font: font, color: color, in: NSRect(x: 46, y: rect.minY, width: nameWidth + 2, height: rect.height))
        if !buddy.activity.isEmpty && buddy.isOnline {
            let x = 46 + nameWidth + 2
            drawText(buddy.activity, font: Theme.ui(10.5), color: isSelected ? .white : Theme.mutedText,
                     in: NSRect(x: x, y: rect.minY, width: max(0, rect.width - x - 4), height: rect.height))
        }
    }

    /// Away, Do Not Disturb and mobile buddies get an icon in place of their avatar, as AIM did for away messages.
    private func statusSymbol(_ buddy: Buddy) -> NSImage? {
        switch buddy.presence {
        case .idle: return Icons.symbol("moon.zzz.fill", size: 12, colors: [Theme.rgb(214, 160, 0)])
        case .dnd: return Icons.symbol("minus.circle.fill", size: 12, colors: [Theme.rgb(200, 50, 40)])
        case .online where buddy.mobileOnly: return Icons.symbol("iphone", size: 12, colors: [Theme.rgb(40, 140, 70)])
        default: return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let i = row(at: p) else { return }
        switch rows[i] {
        case .group(_, let index):
            if collapsed.contains(index) { collapsed.remove(index) } else { collapsed.insert(index) }
            rebuild()
        case .buddy(let buddy):
            selectedID = buddy.id
            selectedChatID = nil
            needsDisplay = true
            if event.clickCount == 2 { onOpen?(buddy) }
        case .chat(let chat):
            selectedChatID = chat.id
            selectedID = nil
            needsDisplay = true
            if event.clickCount == 2 { onOpenChat?(chat) }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = row(at: p), case .buddy(let buddy) = rows[i] else {
            onGroupMenu?(event, self)
            return
        }
        selectedID = buddy.id
        needsDisplay = true
        onMenu?(buddy, event, self)
    }

    override func keyDown(with event: NSEvent) {
        let buddyRows = rows.compactMap { row -> Buddy? in if case .buddy(let b) = row { return b }; return nil }
        let current = buddyRows.firstIndex { $0.id == selectedID }
        switch event.keyCode {
        case 36, 76:
            if let selected {
                onOpen?(selected)
            } else if let chat = chats.first(where: { $0.id == selectedChatID }) {
                onOpenChat?(chat)
            }
        case 125:
            let next = current.map { min($0 + 1, buddyRows.count - 1) } ?? 0
            if buddyRows.indices.contains(next) { selectedID = buddyRows[next].id; needsDisplay = true }
        case 126:
            let next = current.map { max($0 - 1, 0) } ?? 0
            if buddyRows.indices.contains(next) { selectedID = buddyRows[next].id; needsDisplay = true }
        default:
            super.keyDown(with: event)
        }
    }
}

/// The Buddy List window: who is signed on to Discord, with Send IM and Info buttons.
final class BuddyListView: FlippedView {
    var onOpen: ((Buddy) -> Void)?
    var onOpenChat: ((GroupChat) -> Void)?
    var onInfo: ((Buddy) -> Void)?
    var onConnect: (() -> Void)?
    var onHide: ((Buddy) -> Void)?
    var onUnhide: ((String) -> Void)?
    /// Hidden buddy IDs with the name to show for each.
    var hiddenBuddies: [(id: String, name: String)] = []
    /// Everyone with an open direct message, most recent first, friends or not.
    var dmPartners: [Buddy] = []

    let tree = BuddyTreeView()
    private let scroll = NSScrollView()
    private let header = GradientView(colors: [Theme.rgb(255, 255, 255), Theme.rgb(222, 234, 248)],
                                      bottomLine: Theme.toolbarLine)
    private let meLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let connect = ChromeButton(title: "Open People Connection", symbol: "bubble.left.and.bubble.right.fill")
    private let buttons = ButtonBar()
    private let imButton = ChromeButton(title: "IM", symbol: "message.fill")
    private let infoButton = ChromeButton(title: "Info", symbol: "info.circle")
    private var meAvatar: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        meLabel.font = Theme.ui(12, bold: true)
        meLabel.textColor = Theme.rgb(24, 40, 96)
        meLabel.lineBreakMode = .byTruncatingTail
        header.addSubview(meLabel)

        scroll.documentView = tree
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .white

        statusLabel.font = Theme.ui(11)
        statusLabel.textColor = Theme.mutedText
        statusLabel.alignment = .center

        imButton.action = { [weak self] in
            guard let self else { return }
            if let b = self.tree.selected {
                self.onOpen?(b)
            } else if let item = self.dmMenuItem(), let menu = item.submenu {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.imButton.bounds.height), in: self.imButton)
            }
        }
        infoButton.action = { [weak self] in if let b = self?.tree.selected { self?.onInfo?(b) } }
        connect.action = { [weak self] in self?.onConnect?() }
        buttons.buttons = [imButton, infoButton]

        tree.onOpen = { [weak self] buddy in self?.onOpen?(buddy) }
        tree.onOpenChat = { [weak self] chat in self?.onOpenChat?(chat) }
        tree.onMenu = { [weak self] buddy, event, view in
            let menu = NSMenu()
            menu.addItem(ActionItem("Send Instant Message") { self?.onOpen?(buddy) })
            menu.addItem(ActionItem("Open in Discord") { self?.onInfo?(buddy) })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Hide from Buddy List") { self?.onHide?(buddy) })
            if let hidden = self?.hiddenMenuItem() { menu.addItem(hidden) }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        tree.onGroupMenu = { [weak self] event, view in
            guard let self else { return }
            let menu = NSMenu()
            if let item = self.dmMenuItem() { menu.addItem(item) }
            if let item = self.hiddenMenuItem() { menu.addItem(item) }
            guard !menu.items.isEmpty else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        [header, scroll, statusLabel, connect, buttons].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 34)
        meLabel.frame = NSRect(x: 34, y: 9, width: bounds.width - 40, height: 16)
        buttons.frame = NSRect(x: 0, y: bounds.height - 38, width: bounds.width, height: 38)
        scroll.frame = NSRect(x: 0, y: header.frame.maxY, width: bounds.width, height: buttons.frame.minY - header.frame.maxY)
        statusLabel.frame = NSRect(x: 12, y: header.frame.maxY + 30, width: bounds.width - 24, height: 64)
        connect.frame = NSRect(x: (bounds.width - connect.preferredWidth) / 2, y: statusLabel.frame.maxY + 6,
                               width: connect.preferredWidth, height: 24)
        tree.show(lastBuddies, recent: lastRecent, chats: lastChats)
    }

    private var lastBuddies: [Buddy] = []
    private var lastRecent: [Buddy] = []
    private var lastChats: [GroupChat] = []

    private func dmMenuItem() -> NSMenuItem? {
        guard !dmPartners.isEmpty else { return nil }
        let item = NSMenuItem(title: "Send Instant Message To", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for buddy in dmPartners {
            submenu.addItem(ActionItem(buddy.name) { [weak self] in self?.onOpen?(buddy) })
        }
        item.submenu = submenu
        return item
    }

    private func hiddenMenuItem() -> NSMenuItem? {
        guard !hiddenBuddies.isEmpty else { return nil }
        let item = NSMenuItem(title: "Show Hidden Buddy", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for hidden in hiddenBuddies.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            submenu.addItem(ActionItem(hidden.name) { [weak self] in self?.onUnhide?(hidden.id) })
        }
        item.submenu = submenu
        return item
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
    }

    func reload(_ bridge: DiscordBridge, hidden: Set<String>) {
        tree.recentChange = { [weak bridge] id in bridge?.recentChange(for: id) }
        meLabel.stringValue = bridge.me?.name ?? "Buddy List"
        meAvatar = bridge.me?.avatar
        header.needsDisplay = true
        let message: String?
        switch bridge.state {
        case .ready: message = nil
        case .closed: message = "Discord is signed off."
        case .connecting: message = "Signing on to Discord...\nSign in from the People Connection window if Discord asks."
        case .unavailable: message = "AOL-OS could not read your buddies from this version of Discord."
        }
        statusLabel.stringValue = message ?? ""
        statusLabel.isHidden = message == nil
        connect.isHidden = bridge.state == .ready
        scroll.isHidden = message != nil
        imButton.isEnabled = bridge.state == .ready
        infoButton.isEnabled = bridge.state == .ready
        lastBuddies = bridge.sortedBuddies.filter { !hidden.contains($0.id) }
        lastRecent = RecentBuddies.pick(bridge.recentBuddies, hidden: hidden)
        dmPartners = bridge.recentBuddies.filter { !hidden.contains($0.id) }
        lastChats = bridge.groups
        hiddenBuddies = hidden.map { ($0, bridge.buddy($0)?.name ?? $0) }
        tree.show(lastBuddies, recent: lastRecent, chats: lastChats)
        needsDisplay = true
        drawMeAvatar()
    }

    private let meIcon = NSImageView()

    private func drawMeAvatar() {
        if meIcon.superview == nil {
            meIcon.imageScaling = .scaleProportionallyUpOrDown
            meIcon.wantsLayer = true
            meIcon.layer?.cornerRadius = 3
            meIcon.layer?.masksToBounds = true
            meIcon.frame = NSRect(x: 8, y: 6, width: 22, height: 22)
            header.addSubview(meIcon)
        }
        meIcon.image = AvatarCache.image(for: meAvatar) { [weak self] in self?.drawMeAvatar() }
            ?? Icons.symbol("person.crop.square.fill", size: 16, colors: [Theme.aolBlue])
    }
}
