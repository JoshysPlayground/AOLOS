import AppKit
import AVKit
import Photos

/// One picture or video at a time, with Previous and Next through the album it was opened from.
final class PhotoViewerView: FlippedView {
    var onSendInMail: ((PHAsset) -> Void)?
    var onTitle: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private let library: PhotoLibrary
    private let assets: PHFetchResult<PHAsset>
    private(set) var index: Int
    private let photo = PhotoFrameView()
    private let player = AVPlayerView()
    private let bar = ButtonBar()
    private let previous = ChromeButton(title: "Previous", symbol: "chevron.left")
    private let next = ChromeButton(title: "Next", symbol: "chevron.right")
    private let favorite = ChromeButton(title: "Favorite", symbol: "heart")
    private let mail = ChromeButton(title: "Send in Mail", symbol: "envelope")
    private let save = ChromeButton(title: "Save to Disk", symbol: "square.and.arrow.down")
    private var request: PHImageRequestID?
    private var info = ""

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    init(library: PhotoLibrary, assets: PHFetchResult<PHAsset>, index: Int) {
        self.library = library
        self.assets = assets
        self.index = index
        super.init(frame: .zero)
        photo.border = 8
        photo.margin = 14
        player.controlsStyle = .inline
        player.isHidden = true
        previous.action = { [weak self] in self?.step(-1) }
        next.action = { [weak self] in self?.step(1) }
        favorite.action = { [weak self] in self?.toggleFavorite() }
        mail.action = { [weak self] in
            guard let self, let asset = self.asset else { return }
            self.onSendInMail?(asset)
        }
        save.action = { [weak self] in self?.saveOriginal() }
        bar.colors = [Theme.rgb(232, 241, 253), Theme.rgb(200, 219, 245)]
        bar.buttons = [previous, next, favorite, mail, save]
        [photo, player, bar].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    var asset: PHAsset? { index < assets.count ? assets.object(at: index) : nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, request == nil { load() }
    }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: bounds.height - 40, width: bounds.width, height: 40)
        let area = NSRect(x: 0, y: 30, width: bounds.width, height: max(0, bar.frame.minY - 30))
        photo.frame = area
        player.frame = area.insetBy(dx: 14, dy: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient([Theme.rgb(236, 242, 251), Theme.rgb(208, 222, 242)], in: bounds)
        let band = NSRect(x: 0, y: 0, width: bounds.width, height: 30)
        Theme.gradient([Theme.rgb(246, 250, 255), Theme.rgb(222, 234, 250)], in: band)
        Theme.toolbarLine.setFill()
        NSRect(x: 0, y: band.maxY - 1, width: bounds.width, height: 1).fill()
        drawText(info, font: Theme.ui(12, bold: true), color: Theme.rgb(0, 40, 130),
                 in: NSRect(x: 12, y: 0, width: bounds.width - 120, height: 30))
        drawText("\(index + 1) of \(assets.count)", font: Theme.ui(11), color: Theme.mutedText,
                 in: NSRect(x: bounds.width - 112, y: 0, width: 100, height: 30), align: .right)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: step(-1)
        case 124, 49: step(1)
        default: super.keyDown(with: event)
        }
    }

    func stop() {
        player.player?.pause()
        player.player = nil
        if let request { library.cancel(request) }
    }

    private func step(_ delta: Int) {
        let target = index + delta
        guard target >= 0, target < assets.count else { NSSound.beep(); return }
        index = target
        load()
    }

    private func load() {
        guard let asset else { return }
        stop()
        let date = asset.creationDate.map(Self.dateFormat.string) ?? "Picture"
        let name = PhotoLibrary.originalResource(asset)?.originalFilename
        info = name.map { "\(date)    \($0)" } ?? date
        onTitle?(name ?? date)
        previous.isEnabled = index > 0
        next.isEnabled = index < assets.count - 1
        updateFavorite(asset.isFavorite)
        needsDisplay = true

        let id = asset.localIdentifier
        photo.image = nil
        photo.isHidden = false
        player.isHidden = true
        if asset.mediaType == .video {
            library.playerItem(asset) { [weak self] item in
                guard let self, self.asset?.localIdentifier == id, let item else { return }
                self.photo.isHidden = true
                self.player.isHidden = false
                self.player.player = AVPlayer(playerItem: item)
            }
        }
        let screen = NSScreen.main?.frame.size ?? NSSize(width: 1600, height: 1000)
        request = library.image(asset, size: screen, fast: false) { [weak self] image in
            guard let self, self.asset?.localIdentifier == id, let image else { return }
            self.photo.image = image
        }
    }

    private func updateFavorite(_ isFavorite: Bool) {
        favorite.title = isFavorite ? "Unfavorite" : "Favorite"
        favorite.symbol = Icons.symbol(isFavorite ? "heart.fill" : "heart", size: 11, colors: [Theme.aolBlue])
        bar.needsLayout = true
    }

    private func toggleFavorite() {
        guard let asset else { return }
        let id = asset.localIdentifier
        let target = !asset.isFavorite
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.library.toggleFavorite([asset])
                if self.asset?.localIdentifier == id { self.updateFavorite(target) }
            } catch {
                self.onError?(error)
            }
        }
    }

    private func saveOriginal() {
        guard let asset else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        save.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.library.saveOriginals([asset], to: folder)
            } catch {
                self.onError?(error)
            }
            self.save.isEnabled = true
        }
    }
}
