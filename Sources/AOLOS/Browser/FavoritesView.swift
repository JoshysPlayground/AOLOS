import AppKit

struct Favorite: Codable, Equatable {
    var title: String
    var url: String
}

/// Favorite Places manager. Double-click a name or address to edit it.
final class FavoritesView: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var favorites: [Favorite]
    var onChange: (([Favorite]) -> Void)?
    var onOpen: ((Favorite) -> Void)?

    let table = NSTableView()
    private let scroll = NSScrollView()
    private let open = ChromeButton(title: "Open", prominent: true)
    private let remove = ChromeButton(title: "Delete", symbol: "trash")
    private let up = ChromeButton(symbol: "chevron.up")
    private let down = ChromeButton(symbol: "chevron.down")

    init(favorites: [Favorite]) {
        self.favorites = favorites
        super.init(frame: .zero)
        for (id, title, width) in [("title", "Name", 220.0), ("url", "Address", 360.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.isEditable = true
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        [scroll, open, remove, up, down].forEach(addSubview)

        open.action = { [weak self] in self?.openSelected() }
        remove.action = { [weak self] in self?.deleteSelected() }
        up.action = { [weak self] in self?.move(by: -1) }
        down.action = { [weak self] in self?.move(by: 1) }
        up.toolTip = "Move up"
        down.toolTip = "Move down"
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload(_ favorites: [Favorite]) {
        guard favorites != self.favorites else { return }
        self.favorites = favorites
        table.reloadData()
        updateButtons()
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10, h: CGFloat = 24
        let buttonY = bounds.height - pad - h
        scroll.frame = NSRect(x: pad, y: pad, width: bounds.width - 2 * pad, height: max(0, buttonY - 2 * pad))
        open.frame = NSRect(x: pad, y: buttonY, width: max(70, open.preferredWidth), height: h)
        remove.frame = NSRect(x: open.frame.maxX + 6, y: buttonY, width: remove.preferredWidth, height: h)
        down.frame = NSRect(x: bounds.width - pad - 30, y: buttonY, width: 30, height: h)
        up.frame = NSRect(x: down.frame.minX - 4 - 30, y: buttonY, width: 30, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: openSelected()
        case 51, 117: deleteSelected()
        default: super.keyDown(with: event)
        }
    }

    private var selected: Int? {
        favorites.indices.contains(table.selectedRow) ? table.selectedRow : nil
    }

    private func updateButtons() {
        open.isEnabled = selected != nil
        remove.isEnabled = selected != nil
        up.isEnabled = (selected ?? 0) > 0
        down.isEnabled = selected.map { $0 < favorites.count - 1 } ?? false
    }

    private func commit() {
        onChange?(favorites)
        updateButtons()
    }

    private func openSelected() {
        if let i = selected { onOpen?(favorites[i]) }
    }

    private func deleteSelected() {
        guard let i = selected else { return }
        favorites.remove(at: i)
        table.reloadData()
        if !favorites.isEmpty {
            table.selectRowIndexes(IndexSet(integer: min(i, favorites.count - 1)), byExtendingSelection: false)
        }
        commit()
    }

    private func move(by delta: Int) {
        guard let i = selected, favorites.indices.contains(i + delta) else { return }
        favorites.swapAt(i, i + delta)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: i + delta), byExtendingSelection: false)
        commit()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { favorites.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard favorites.indices.contains(row) else { return nil }
        return tableColumn?.identifier.rawValue == "url" ? favorites[row].url : favorites[row].title
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard favorites.indices.contains(row) else { return }
        let value = (object as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if tableColumn?.identifier.rawValue == "url" {
            guard let url = Session.webURL(from: value) else { NSSound.beep(); return }
            favorites[row].url = url.absoluteString
        } else {
            favorites[row].title = value
        }
        commit()
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
}
