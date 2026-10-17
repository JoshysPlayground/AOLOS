import AppKit

/// A plain selectable list with an optional icon and a bold flag per row, drawn in AOL style.
final class PickList: FlippedView {
    struct Item {
        let id: String
        let title: String
        var detail = ""
        var icon: NSImage?
        var iconURL: URL?
        var bold = false
        var isHeader = false
        /// A non-selectable indented line, such as a person in a voice channel.
        var isNote = false
    }

    var items: [Item] = [] { didSet { resize(); needsDisplay = true } }
    private(set) var selectedID: String?
    var onSelect: ((Item) -> Void)?
    var onOpen: ((Item) -> Void)?
    /// Right click on a selectable row or a header. A selectable row is selected first.
    var onMenu: ((Item, NSEvent) -> Void)?
    static let rowHeight: CGFloat = 20

    override var acceptsFirstResponder: Bool { true }

    var selected: Item? { items.first { $0.id == selectedID && !$0.isHeader && !$0.isNote } }

    func select(_ id: String?) {
        selectedID = id
        needsDisplay = true
    }

    private func resize() {
        let height = max(CGFloat(items.count) * Self.rowHeight + 4, enclosingScrollView?.contentSize.height ?? 0)
        setFrameSize(NSSize(width: enclosingScrollView?.contentSize.width ?? bounds.width, height: height))
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resize()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paper.setFill()
        bounds.fill()
        for (i, item) in items.enumerated() {
            let rect = NSRect(x: 0, y: 2 + CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
            guard rect.intersects(dirtyRect) else { continue }
            if item.isHeader {
                drawText(item.title.uppercased(), font: Theme.ui(10, bold: true), color: Theme.mutedText,
                         in: rect.insetBy(dx: 6, dy: 0))
                continue
            }
            if item.isNote {
                drawText(item.title, font: Theme.ui(11), color: Theme.mutedText,
                         in: NSRect(x: 40, y: rect.minY, width: rect.width - 46, height: rect.height))
                continue
            }
            let isSelected = item.id == selectedID
            if isSelected {
                Theme.hover.setFill()
                rect.insetBy(dx: 2, dy: 0).fill()
            }
            var x: CGFloat = 8
            let icon = AvatarCache.image(for: item.iconURL) { [weak self] in self?.needsDisplay = true } ?? item.icon
            if let icon {
                NSGraphicsContext.saveGraphicsState()
                let iconRect = NSRect(x: x, y: rect.midY - 8, width: 16, height: 16)
                NSBezierPath(roundedRect: iconRect, xRadius: 4, yRadius: 4).addClip()
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                x += 22
            }
            drawText(item.title, font: Theme.ui(12, bold: item.bold), color: isSelected ? .white : Theme.text,
                     in: NSRect(x: x, y: rect.minY, width: rect.width - x - 6, height: rect.height))
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let i = Int((p.y - 2) / Self.rowHeight)
        guard items.indices.contains(i), !items[i].isHeader, !items[i].isNote else { return }
        selectedID = items[i].id
        needsDisplay = true
        onSelect?(items[i])
        if event.clickCount == 2 { onOpen?(items[i]) }
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int((p.y - 2) / Self.rowHeight)
        guard p.y >= 2, items.indices.contains(i), !items[i].isNote else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        if !items[i].isHeader, selectedID != items[i].id {
            selectedID = items[i].id
            needsDisplay = true
            onSelect?(items[i])
        }
        onMenu?(items[i], event)
    }

    override func keyDown(with event: NSEvent) {
        let rows = items.filter { !$0.isHeader && !$0.isNote }
        let current = rows.firstIndex { $0.id == selectedID }
        switch event.keyCode {
        case 36, 76:
            if let selected { onOpen?(selected) }
        case 125, 126:
            let next = current.map { event.keyCode == 125 ? min($0 + 1, rows.count - 1) : max($0 - 1, 0) } ?? 0
            guard rows.indices.contains(next) else { return }
            selectedID = rows[next].id
            needsDisplay = true
            onSelect?(rows[next])
        default:
            super.keyDown(with: event)
        }
    }
}

/// The AOL Find a Chat window: Discord servers on the left, their text channels as rooms on the right.
final class ChatRoomsView: FlippedView {
    var onPickServer: ((ChatServer) -> Void)?
    var onEnter: ((ChatServer, ChatRoom) -> Void)?
    var onRefresh: (() -> Void)?
    var onLeaveVoice: (() -> Void)?
    var onToggleFavorite: ((ChatServer, ChatRoom) -> Void)?
    var onToggleMute: ((String) -> Void)?
    /// Muted server, category and room IDs. Muted rows show a muted speaker.
    var mutedIDs: [String] = [] {
        didSet {
            guard mutedIDs != oldValue else { return }
            showServers(servers)
            if !rooms.isEmpty { showRooms(rooms) }
        }
    }
    /// Favorite room IDs in pin order. They are listed first, under a Favorites header.
    var favoriteRoomIDs: [String] = [] {
        didSet { if favoriteRoomIDs != oldValue, !rooms.isEmpty { showRooms(rooms) } }
    }

    private let header = GradientView(colors: [Theme.rgb(74, 138, 222), Theme.rgb(30, 88, 184)], bottomLine: Theme.rgb(18, 58, 140))
    private let title = NSTextField(labelWithString: "Find a Chat")
    private let serverLabel = NSTextField(labelWithString: "Categories")
    private let roomLabel = NSTextField(labelWithString: "Rooms")
    private let serverScroll = NSScrollView()
    private let roomScroll = NSScrollView()
    let serverList = PickList()
    private let roomList = PickList()
    private let buttons = ButtonBar()
    private let enter = ChromeButton(title: "Enter Chat", symbol: "bubble.left.and.bubble.right.fill", prominent: true)
    private let refresh = ChromeButton(title: "Refresh", symbol: "arrow.clockwise")
    private let leave = ChromeButton(title: "Leave Voice", symbol: "phone.down.fill")
    private var servers: [ChatServer] = []
    private var rooms: [ChatRoom] = []
    private var currentServer: ChatServer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Theme.caption(16)
        title.textColor = .white
        header.addSubview(title)
        for label in [serverLabel, roomLabel] {
            label.font = Theme.ui(12, bold: true)
            label.textColor = Theme.rgb(24, 40, 96)
        }
        for (scroll, list) in [(serverScroll, serverList), (roomScroll, roomList)] {
            scroll.documentView = list
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
        }
        serverList.onSelect = { [weak self] item in
            guard let self, let server = self.servers.first(where: { $0.id == item.id }) else { return }
            self.currentServer = server
            self.roomLabel.stringValue = "Rooms in \(server.name)"
            self.showRooms([], loading: true)
            self.onPickServer?(server)
        }
        roomList.onOpen = { [weak self] _ in self?.enterSelected() }
        roomList.onSelect = { [weak self] item in
            let voice = self?.rooms.first { $0.id == item.id }?.voice == true
            self?.enter.title = voice ? "Join Voice" : "Enter Chat"
            self?.buttons.needsLayout = true
        }
        serverList.onMenu = { [weak self] item, event in
            guard let self else { return }
            let menu = NSMenu()
            menu.addItem(self.muteItem(item.id, "Server"))
            NSMenu.popUpContextMenu(menu, with: event, for: self.serverList)
        }
        roomList.onMenu = { [weak self] item, event in
            guard let self else { return }
            if item.isHeader {
                let id = String(item.id.dropFirst(Self.categoryPrefix.count))
                guard item.id.hasPrefix(Self.categoryPrefix), !id.isEmpty else { return }
                let menu = NSMenu()
                menu.addItem(self.muteItem(id, "Category"))
                NSMenu.popUpContextMenu(menu, with: event, for: self.roomList)
                return
            }
            guard let room = self.rooms.first(where: { $0.id == item.id }) else { return }
            let menu = NSMenu()
            menu.addItem(ActionItem(room.voice ? "Join Voice" : "Enter Chat") { [weak self] in self?.enterSelected() })
            menu.addItem(.separator())
            let isFavorite = self.favoriteRoomIDs.contains(room.id)
            menu.addItem(ActionItem(isFavorite ? "Remove from Favorites" : "Add to Favorites") { [weak self] in
                guard let self, let server = self.currentServer else { return }
                self.onToggleFavorite?(server, room)
            })
            if !room.voice {
                menu.addItem(self.muteItem(room.id, "Room"))
                if !self.mutedIDs.contains(room.id), self.isMuted(room) {
                    let note = NSMenuItem(title: "Muted by its category or server", action: nil, keyEquivalent: "")
                    note.isEnabled = false
                    menu.addItem(note)
                }
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self.roomList)
        }
        leave.action = { [weak self] in self?.onLeaveVoice?() }
        enter.action = { [weak self] in self?.enterSelected() }
        refresh.action = { [weak self] in self?.onRefresh?() }
        buttons.buttons = [enter, refresh, leave]
        [header, serverLabel, roomLabel, serverScroll, roomScroll, buttons].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 36)
        title.frame = NSRect(x: 12, y: 8, width: bounds.width - 24, height: 22)
        buttons.frame = NSRect(x: 0, y: bounds.height - 42, width: bounds.width, height: 42)
        let top = header.frame.maxY + 8
        let left = floor(bounds.width * 0.42)
        serverLabel.frame = NSRect(x: 10, y: top, width: left - 15, height: 16)
        roomLabel.frame = NSRect(x: left + 5, y: top, width: bounds.width - left - 15, height: 16)
        let listTop = top + 20
        let listHeight = buttons.frame.minY - listTop - 8
        serverScroll.frame = NSRect(x: 10, y: listTop, width: left - 15, height: listHeight)
        roomScroll.frame = NSRect(x: left + 5, y: listTop, width: bounds.width - left - 15, height: listHeight)
        serverList.items = serverList.items
        roomList.items = roomList.items
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
    }

    private static let categoryPrefix = "cat-"
    private static let mutedMark = "  \u{1F507}"

    private func muteItem(_ id: String, _ kind: String) -> NSMenuItem {
        ActionItem(mutedIDs.contains(id) ? "Unmute \(kind)" : "Mute \(kind)") { [weak self] in self?.onToggleMute?(id) }
    }

    private func isMuted(_ room: ChatRoom) -> Bool {
        guard let server = currentServer else { return mutedIDs.contains(room.id) }
        return ChatMute.isMuted(room, in: server, muted: mutedIDs)
    }

    func showServers(_ servers: [ChatServer]) {
        self.servers = servers
        serverList.items = servers.map {
            PickList.Item(id: $0.id, title: $0.name + (mutedIDs.contains($0.id) ? Self.mutedMark : ""), icon: Icons.symbol("person.3.fill", size: 11, colors: [Theme.aolBlue]),
                          iconURL: $0.iconURL)
        }
        if let current = currentServer, servers.contains(where: { $0.id == current.id }) {
            serverList.select(current.id)
        }
    }

    func showRooms(_ rooms: [ChatRoom], loading: Bool = false, error: String? = nil) {
        self.rooms = rooms
        if let error {
            roomList.items = [PickList.Item(id: "_", title: error, isHeader: true)]
            return
        }
        if loading {
            roomList.items = [PickList.Item(id: "_", title: "Loading rooms...", isHeader: true)]
            return
        }
        var items: [PickList.Item] = []
        let favorites = favoriteRoomIDs.compactMap { id in rooms.first { $0.id == id } }
        if !favorites.isEmpty {
            items.append(PickList.Item(id: "_favorites", title: "\u{2665} Favorites", isHeader: true))
            favorites.forEach { appendRoom($0, to: &items) }
        }
        var category: String?
        for room in rooms where !favoriteRoomIDs.contains(room.id) {
            if room.category != category {
                category = room.category
                if !room.category.isEmpty {
                    let muted = !room.categoryID.isEmpty && mutedIDs.contains(room.categoryID)
                    items.append(PickList.Item(id: Self.categoryPrefix + (room.categoryID.isEmpty ? "" : room.categoryID),
                                               title: room.category + (muted ? Self.mutedMark : ""), isHeader: true))
                }
            }
            appendRoom(room, to: &items)
        }
        if items.isEmpty { items = [PickList.Item(id: "_", title: "No rooms you can read", isHeader: true)] }
        let selected = roomList.selectedID
        roomList.items = items
        roomList.select(selected)
    }

    private func appendRoom(_ room: ChatRoom, to items: inout [PickList.Item]) {
        if room.voice {
            let title = room.joined ? "\u{1F50A} \(room.name) (connected)" : "\u{1F50A} \(room.name)"
            items.append(PickList.Item(id: room.id, title: title, bold: room.joined))
            for person in room.people {
                items.append(PickList.Item(id: "\(room.id)-\(person)", title: person, isNote: true))
            }
        } else {
            items.append(PickList.Item(id: room.id, title: "# \(room.name)" + (isMuted(room) ? Self.mutedMark : ""),
                                       bold: room.unread))
        }
    }

    /// Reloads the rooms of the selected server, keeping the selection. Voice channel members change often.
    func reloadRooms() {
        guard let server = currentServer else { return }
        onPickServer?(server)
    }

    func setStatus(_ text: String) {
        buttons.statusLabel.stringValue = text
    }

    private func enterSelected() {
        guard let server = currentServer, let item = roomList.selected,
              let room = rooms.first(where: { $0.id == item.id }) else { NSSound.beep(); return }
        onEnter?(server, room)
    }
}
