import AppKit
import Photos

/// A picture drawn like a print: white border and a soft drop shadow, fitted inside the view.
final class PhotoFrameView: FlippedView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var badge: String? { didSet { needsDisplay = true } }
    var border: CGFloat = 5
    var margin: CGFloat = 8

    func photoRect() -> NSRect {
        let box = bounds.insetBy(dx: border + margin, dy: border + margin)
        guard let image, image.size.width > 0, image.size.height > 0, box.width > 0, box.height > 0 else { return box }
        let s = min(box.width / image.size.width, box.height / image.size.height)
        let w = image.size.width * s, h = image.size.height * s
        return NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h).integral
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = photoRect()
        let frame = rect.insetBy(dx: -border, dy: -border)
        if isSelected {
            let ring = NSBezierPath(roundedRect: frame.insetBy(dx: -4, dy: -4), xRadius: 4, yRadius: 4)
            Theme.hover.withAlphaComponent(0.85).setFill()
            ring.fill()
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 1, height: -2)
        shadow.shadowBlurRadius = 3
        shadow.set()
        NSColor.white.setFill()
        frame.fill()
        NSGraphicsContext.restoreGraphicsState()
        Theme.rgb(186, 190, 198).setStroke()
        NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5)).stroke()

        if let image {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            Theme.rgb(232, 238, 246).setFill()
            rect.fill()
        }

        if let badge {
            let font = Theme.ui(10, bold: true)
            let width = (badge as NSString).size(withAttributes: [.font: font]).width + 24
            let pill = NSRect(x: rect.maxX - width - 4, y: rect.maxY - 20, width: width, height: 16)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
            Icons.symbol("play.fill", size: 8, colors: [.white])?.draw(
                in: NSRect(x: pill.minX + 6, y: pill.minY + 4, width: 8, height: 8),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            drawText(badge, font: font, color: .white, in: NSRect(x: pill.minX + 17, y: pill.minY, width: width - 18, height: 16))
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

final class PhotoItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("PhotoItem")
    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private let frameView = PhotoFrameView()
    private let caption = NSTextField(labelWithString: "")
    private weak var library: PhotoLibrary?
    private var request: PHImageRequestID?
    private var assetID: String?

    override func loadView() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 150, height: 158))
        caption.font = Theme.ui(11)
        caption.textColor = Theme.mutedText
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        frameView.autoresizingMask = [.width]
        caption.autoresizingMask = [.width]
        frameView.frame = NSRect(x: 0, y: 0, width: 150, height: 136)
        caption.frame = NSRect(x: 4, y: 138, width: 142, height: 16)
        [frameView, caption].forEach(root.addSubview)
        view = root
    }

    override var isSelected: Bool {
        didSet { frameView.isSelected = isSelected }
    }

    func show(_ asset: PHAsset, library: PhotoLibrary) {
        if let request { self.library?.cancel(request) }
        self.library = library
        assetID = asset.localIdentifier
        frameView.image = nil
        frameView.badge = asset.mediaType == .video ? PhotoFrameView.duration(asset.duration) : nil
        caption.stringValue = asset.creationDate.map(Self.dateFormat.string) ?? ""
        let id = asset.localIdentifier
        request = library.image(asset, size: NSSize(width: 150, height: 130), fast: true) { [weak self] image in
            guard let self, self.assetID == id, let image else { return }
            self.frameView.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let request { library?.cancel(request) }
        request = nil
        assetID = nil
        frameView.image = nil
    }
}

/// Opens a picture on double click, which NSCollectionView does not report on its own.
final class PhotoGridView: NSCollectionView {
    var onDoubleClick: ((IndexPath) -> Void)?
    var onReturn: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2,
              let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return }
        onDoubleClick?(path)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}

/// AOL Pictures: the Mac's Photos library with albums on the left and prints in a grid.
final class PicturesView: FlippedView, NSCollectionViewDataSource, NSCollectionViewDelegate,
                          NSTableViewDataSource, NSTableViewDelegate {
    enum Action { case view, sendInMail, favorite, save, upload, openPhotos }

    var onView: ((PHFetchResult<PHAsset>, Int) -> Void)?
    var onSendInMail: (([PHAsset]) -> Void)?
    var onError: ((Error) -> Void)?
    var onOpenLink: ((URL) -> Void)?

    let library: PhotoLibrary
    private let header = MailHeaderBar()
    private let albumTitle = GradientView(colors: [Theme.rgb(226, 237, 252), Theme.rgb(190, 212, 242)])
    private let albumTable = NSTableView()
    private let albumScroll = NSScrollView()
    private let grid = PhotoGridView()
    private let gridScroll = NSScrollView()
    private let bar = ButtonBar()
    private let accessPanel = FlippedView()
    private let accessLabel = NSTextField(wrappingLabelWithString: "")
    private let accessButton = ChromeButton(title: "Allow Access to Photos", symbol: "photo.on.rectangle", prominent: true)
    private var buttons: [Action: ChromeButton] = [:]
    private var albums: [PhotoAlbum] = []
    private var album: PhotoAlbum?
    private var assets: PHFetchResult<PHAsset>?
    private var busy: String?

    private static let bandHeight: CGFloat = 30
    private static let numberFormat: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    init(library: PhotoLibrary) {
        self.library = library
        super.init(frame: .zero)

        header.titles = ["All Pictures", "Favorites", "My Albums"]
        header.menuTitles = ["Picture Options", "Help"]
        header.onSelect = { [weak self] i in self?.selectTab(i) }
        header.onMenu = { [weak self] i, point in self?.showHeaderMenu(i, at: point) }

        let albumLabel = NSTextField(labelWithString: "My Albums")
        albumLabel.font = Theme.ui(12, bold: true)
        albumLabel.textColor = Theme.rgb(0, 40, 130)
        albumLabel.frame = NSRect(x: 8, y: 5, width: 170, height: 18)
        albumTitle.addSubview(albumLabel)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("album"))
        column.resizingMask = .autoresizingMask
        albumTable.addTableColumn(column)
        albumTable.headerView = nil
        albumTable.rowHeight = 20
        albumTable.style = .plain
        albumTable.backgroundColor = Theme.rgb(240, 246, 254)
        albumTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        albumTable.dataSource = self
        albumTable.delegate = self
        albumScroll.documentView = albumTable
        albumScroll.hasVerticalScroller = true
        albumScroll.borderType = .noBorder
        albumScroll.drawsBackground = false

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 150, height: 158)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        grid.collectionViewLayout = layout
        grid.register(PhotoItem.self, forItemWithIdentifier: PhotoItem.id)
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [.white]
        grid.dataSource = self
        grid.delegate = self
        grid.registerForDraggedTypes([.fileURL])
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        grid.onDoubleClick = { [weak self] path in self?.open(path.item) }
        grid.onReturn = { [weak self] in self?.perform(.view) }
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.borderType = .noBorder

        let specs: [(Action, String, String)] = [
            (.view, "View", "eye"), (.sendInMail, "Send in Mail", "envelope"), (.favorite, "Favorite", "heart"),
            (.save, "Save to Disk", "square.and.arrow.down"), (.upload, "Upload Pictures", "square.and.arrow.up"),
            (.openPhotos, "Open Photos", "photo.on.rectangle"),
        ]
        bar.colors = [Theme.rgb(232, 241, 253), Theme.rgb(200, 219, 245)]
        bar.buttons = specs.map { action, title, symbol in
            let b = ChromeButton(title: title, symbol: symbol)
            b.action = { [weak self] in self?.perform(action) }
            buttons[action] = b
            return b
        }

        accessLabel.font = Theme.ui(13)
        accessLabel.alignment = .center
        accessButton.action = { [weak self] in self?.requestAccess() }
        [accessLabel, accessButton].forEach(accessPanel.addSubview)

        [header, albumTitle, albumScroll, gridScroll, bar, accessPanel].forEach(addSubview)
        library.startObserving()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 32)
        bar.frame = NSRect(x: 0, y: bounds.height - 40, width: bounds.width, height: 40)
        let top: CGFloat = 32
        let height = max(0, bar.frame.minY - top)
        let side: CGFloat = bounds.width > 640 ? 190 : 0
        albumTitle.isHidden = side == 0
        albumScroll.isHidden = side == 0
        albumTitle.frame = NSRect(x: 0, y: top, width: side, height: 28)
        albumScroll.frame = NSRect(x: 0, y: top + 28, width: side, height: max(0, height - 28))
        let x = side == 0 ? 0 : side + 1
        gridScroll.frame = NSRect(x: x, y: top + Self.bandHeight, width: bounds.width - x,
                                  height: max(0, height - Self.bandHeight))
        accessPanel.frame = NSRect(x: 0, y: top, width: bounds.width, height: height)
        let w = min(480, accessPanel.bounds.width - 40)
        accessLabel.frame = NSRect(x: (accessPanel.bounds.width - w) / 2, y: 70, width: w, height: 60)
        let bw = accessButton.preferredWidth + 12
        accessButton.frame = NSRect(x: (accessPanel.bounds.width - bw) / 2, y: 146, width: bw, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paper.setFill()
        bounds.fill()
        guard library.isAuthorized else { return }
        let band = NSRect(x: gridScroll.frame.minX, y: 32, width: gridScroll.frame.width, height: Self.bandHeight)
        Theme.gradient([Theme.rgb(246, 250, 255), Theme.rgb(222, 234, 250)], in: band)
        Theme.toolbarLine.setFill()
        NSRect(x: band.minX, y: band.maxY - 1, width: band.width, height: 1).fill()
        drawText(album?.title ?? "", font: Theme.ui(14, bold: true), color: Theme.rgb(0, 40, 130),
                 in: NSRect(x: band.minX + 12, y: band.minY, width: band.width * 0.6, height: band.height))
        let count = assets?.count ?? 0
        let noun = count == 1 ? "item" : "items"
        drawText("\(Self.numberFormat.string(from: count as NSNumber) ?? "\(count)") \(noun)", font: Theme.ui(11),
                 color: Theme.mutedText, in: NSRect(x: band.maxX - 212, y: band.minY, width: 200, height: band.height),
                 align: .right)
        if !albumScroll.isHidden {
            Theme.rgb(240, 246, 254).setFill()
            albumScroll.frame.fill()
            Theme.toolbarLine.setFill()
            NSRect(x: albumScroll.frame.maxX, y: 32, width: 1, height: albumScroll.frame.maxY - 32).fill()
            NSRect(x: 0, y: albumTitle.frame.maxY - 1, width: albumScroll.frame.width, height: 1).fill()
        }
    }

    func reload() {
        let authorized = library.isAuthorized
        accessPanel.isHidden = authorized
        [albumTitle, albumScroll, gridScroll].forEach { $0.isHidden = !authorized }
        if !authorized {
            if library.status == .notDetermined {
                accessLabel.stringValue = "AOL Pictures shows the photos and videos in your Mac's Photos library."
                accessButton.title = "Allow Access to Photos"
            } else {
                accessLabel.stringValue = "AOL-OS can't see your Photos library. Turn it on in System Settings under Privacy & Security, then Photos."
                accessButton.title = "Open Privacy Settings"
            }
            albums = []
            assets = nil
            needsLayout = true
            updateButtons()
            needsDisplay = true
            return
        }

        let selected = Set(selectedAssets.map(\.localIdentifier))
        albums = library.albums()
        if let current = album, let fresh = albums.first(where: { $0.id == current.id }) {
            album = fresh
        } else {
            album = albums.first
        }
        if let album { assets = library.assets(in: album) }
        albumTable.reloadData()
        if let i = rows.firstIndex(where: { if case .album(let a) = $0 { return a.id == album?.id } else { return false } }) {
            albumTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        header.selected = tabIndex
        grid.reloadData()
        if let assets, !selected.isEmpty {
            var paths = Set<IndexPath>()
            assets.enumerateObjects { asset, i, _ in
                if selected.contains(asset.localIdentifier) { paths.insert(IndexPath(item: i, section: 0)) }
            }
            grid.selectionIndexPaths = paths
        }
        updateButtons()
        needsDisplay = true
    }

    private var tabIndex: Int {
        guard let album else { return 0 }
        if album.kind == .all { return 0 }
        return album.isFavorites ? 1 : 2
    }

    private enum Row {
        case heading(String)
        case album(PhotoAlbum)
    }

    private var rows: [Row] {
        var out: [Row] = [.heading("Library")]
        out += albums.filter { $0.kind != .user }.map(Row.album)
        let user = albums.filter { $0.kind == .user }
        if !user.isEmpty { out.append(.heading("Albums")) }
        return out + user.map(Row.album)
    }

    var selectedAssets: [PHAsset] {
        guard let assets else { return [] }
        return grid.selectionIndexPaths.map(\.item).sorted().filter { $0 < assets.count }.map { assets.object(at: $0) }
    }

    private func select(_ newAlbum: PhotoAlbum) {
        guard newAlbum.id != album?.id else { return }
        album = newAlbum
        assets = library.assets(in: newAlbum)
        grid.reloadData()
        grid.scroll(.zero)
        reload()
    }

    private func selectTab(_ i: Int) {
        let target: PhotoAlbum?
        switch i {
        case 0: target = albums.first { $0.kind == .all }
        case 1: target = albums.first { $0.isFavorites }
        default: target = albums.first { $0.kind == .user }
        }
        if let target { select(target) } else { header.selected = tabIndex }
    }

    private func requestAccess() {
        if library.status == .notDetermined {
            Task { [weak self] in
                _ = await self?.library.authorize()
                self?.reload()
            }
        } else {
            onOpenLink?(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
        }
    }

    private func showHeaderMenu(_ index: Int, at point: NSPoint) {
        let menu = NSMenu()
        if index == 0 {
            menu.addItem(ActionItem("Upload Pictures...") { [weak self] in self?.perform(.upload) })
            menu.addItem(ActionItem("Open Photos") { [weak self] in self?.perform(.openPhotos) })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Refresh") { [weak self] in self?.reload() })
        } else {
            menu.addItem(ActionItem("Photos Access Settings") { [weak self] in
                self?.onOpenLink?(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
            })
        }
        menu.popUp(positioning: nil, at: point, in: header)
    }

    private func enabled(_ action: Action, for selection: [PHAsset]) -> Bool {
        guard library.isAuthorized, busy == nil else { return action == .openPhotos }
        switch action {
        case .view: return selection.count >= 1
        case .sendInMail: return (1...10).contains(selection.count)
        case .favorite, .save: return !selection.isEmpty
        case .upload: return album?.acceptsUploads ?? true
        case .openPhotos: return true
        }
    }

    private func updateButtons() {
        let selection = selectedAssets
        for (action, button) in buttons { button.isEnabled = enabled(action, for: selection) }
        let allFavorite = !selection.isEmpty && selection.allSatisfy(\.isFavorite)
        buttons[.favorite]?.title = allFavorite ? "Unfavorite" : "Favorite"
        buttons[.favorite]?.symbol = Icons.symbol(allFavorite ? "heart.slash" : "heart", size: 11, colors: [Theme.aolBlue])
        bar.needsLayout = true
        if let busy {
            bar.statusLabel.stringValue = busy
        } else if !library.isAuthorized {
            bar.statusLabel.stringValue = "Photos access is off."
        } else {
            bar.statusLabel.stringValue = selection.isEmpty ? "Double-click a picture to view it." : "\(selection.count) selected"
        }
    }

    private func perform(_ action: Action) {
        let selection = selectedAssets
        guard enabled(action, for: selection) else { return }
        switch action {
        case .view:
            if let first = grid.selectionIndexPaths.map(\.item).min() { open(first) }
        case .sendInMail:
            onSendInMail?(selection)
        case .favorite:
            run("Updating favorites...") { try await $0.library.toggleFavorite(selection) }
        case .save:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Save Here"
            panel.message = "Choose a folder for the original files."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            run("Saving \(selection.count) item\(selection.count == 1 ? "" : "s")...") {
                _ = try await $0.library.saveOriginals(selection, to: folder)
            }
        case .upload:
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.image, .movie]
            panel.prompt = "Upload"
            panel.message = "Pictures and videos are added to your Photos library."
            guard panel.runModal() == .OK else { return }
            upload(panel.urls)
        case .openPhotos:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    private func upload(_ urls: [URL]) {
        let files = urls.filter(PhotoLibrary.isMedia)
        guard !files.isEmpty else { return }
        let target = album?.acceptsUploads == true ? album : nil
        run("Uploading \(files.count) item\(files.count == 1 ? "" : "s")...") {
            try await $0.library.importFiles(files, into: target)
        }
    }

    private func run(_ status: String, _ work: @escaping (PicturesView) async throws -> Void) {
        busy = status
        updateButtons()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self)
            } catch {
                self.onError?(error)
            }
            self.busy = nil
            self.updateButtons()
        }
    }

    private func open(_ index: Int) {
        guard let assets, index < assets.count else { return }
        onView?(assets, index)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .heading = rows[row] { return false }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = albumTable.selectedRow
        guard row >= 0, row < rows.count, case .album(let a) = rows[row] else { return }
        select(a)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("albumCell"), owner: nil) as? FolderCell
            ?? FolderCell()
        cell.identifier = NSUserInterfaceItemIdentifier("albumCell")
        switch rows[row] {
        case .heading(let title):
            cell.configure(title: title, symbol: nil, indent: 0, bold: true, heading: true)
        case .album(let a):
            cell.configure(title: "\(a.title) (\(Self.numberFormat.string(from: a.count as NSNumber) ?? "\(a.count)"))",
                           symbol: PhotoLibrary.symbol(for: a), indent: 1)
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        assets?.count ?? 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PhotoItem.id, for: indexPath)
        if let item = item as? PhotoItem, let assets, indexPath.item < assets.count {
            item.show(assets.object(at: indexPath.item), library: library)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { updateButtons() }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateButtons() }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard enabled(.upload, for: []), !droppedFiles(draggingInfo).isEmpty else { return [] }
        dropOperation.pointee = .before
        return .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let files = droppedFiles(draggingInfo)
        guard !files.isEmpty else { return false }
        upload(files)
        return true
    }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(PhotoLibrary.isMedia)
    }
}
