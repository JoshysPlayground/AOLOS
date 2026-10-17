import AppKit

/// The Luna title bar. In a window it replaces the macOS title bar, which is made transparent behind it.
final class AppTitleBar: FlippedView {
    let minButton = CaptionButton(kind: .minimize)
    let maxButton = CaptionButton(kind: .maximize)
    let closeButton = CaptionButton(kind: .close)
    var title = "AOL Operating System" { didSet { needsDisplay = true } }
    var onDoubleClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(minButton)
        addSubview(maxButton)
        addSubview(closeButton)
        maxButton.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name, object: window)
        }
    }

    @objc private func keyChanged() { needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func layout() {
        super.layout()
        let s = bounds.height - 6
        var x = bounds.width - s - 5
        for button in [closeButton, maxButton, minButton] where !button.isHidden {
            button.frame = NSRect(x: x, y: 3, width: s, height: s)
            x -= s + 2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(window?.isKeyWindow == false ? Theme.titleInactive : Theme.titleActive, in: bounds)
        if let icon = Icons.brandOrTriangle() {
            icon.draw(in: NSRect(x: 6, y: (bounds.height - 18) / 2, width: 18, height: 18),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawText(title, font: Theme.caption(13), color: .white,
                 in: NSRect(x: 30, y: 0, width: bounds.width - 120, height: bounds.height), shadow: true)
    }
}

final class MenuRow: FlippedView {
    private var items: [MenuRowItem] = []

    func setItems(_ items: [MenuRowItem]) {
        self.items.forEach { $0.removeFromSuperview() }
        self.items = items
        items.forEach(addSubview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 4
        for item in items {
            item.frame = NSRect(x: x, y: 0, width: item.preferredWidth, height: bounds.height)
            x += item.preferredWidth
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.menuBar.setFill()
        bounds.fill()
    }
}

/// The AOL 9 toolbar: main buttons on the left, a framed group with AOL Radio now playing on the right, then the logo.
final class ToolbarView: FlippedView {
    var leftItems: [ToolbarButton] = [] { didSet { replace(oldValue, with: leftItems) } }
    var groupItems: [ToolbarButton] = [] { didSet { replace(oldValue, with: groupItems) } }
    let nowPlaying = NowPlayingWidget()
    let customize = ChromeButton(symbol: "checkmark.square")
    private var groupRect = NSRect.zero
    static let itemWidth: CGFloat = 64
    static let nowPlayingWidth: ClosedRange<CGFloat> = 170...300

    override init(frame: NSRect) {
        super.init(frame: frame)
        [nowPlaying, customize].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func replace(_ old: [ToolbarButton], with new: [ToolbarButton]) {
        old.forEach { $0.removeFromSuperview() }
        new.forEach(addSubview)
        needsLayout = true
    }

    private var logoRect: NSRect {
        NSRect(x: bounds.width - 46, y: (bounds.height - 38) / 2, width: 38, height: 38)
    }

    override func layout() {
        super.layout()
        let h = bounds.height - 6
        var x: CGFloat = 6
        for item in leftItems {
            item.frame = NSRect(x: x, y: 3, width: Self.itemWidth, height: h)
            x += Self.itemWidth
        }

        groupRect = NSRect(x: x + 14, y: 3, width: max(0, logoRect.minX - 10 - x - 14), height: h)
        let customizeW: CGFloat = 22
        customize.frame = NSRect(x: groupRect.maxX - customizeW - 4, y: groupRect.maxY - 22, width: customizeW, height: 18)

        let inner = NSRect(x: groupRect.minX + 6, y: groupRect.minY,
                           width: max(0, groupRect.width - customizeW - 16), height: h)
        let widths = groupItems.map { $0.preferredWidth(minWidth: Self.itemWidth) }
        let gap: CGFloat = 6
        let itemsWidth = widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1))
        let widgetW = min(Self.nowPlayingWidth.upperBound, inner.width - itemsWidth - 12)
        nowPlaying.isHidden = widgetW < Self.nowPlayingWidth.lowerBound
        if !nowPlaying.isHidden {
            nowPlaying.frame = NSRect(x: inner.maxX - widgetW, y: inner.minY + 4, width: widgetW, height: inner.height - 8)
        }

        let limit = nowPlaying.isHidden ? inner.maxX : nowPlaying.frame.minX - 8
        var gx = inner.minX + 4
        var overflow = false
        for (item, width) in zip(groupItems, widths) {
            overflow = overflow || gx + width > limit
            item.isHidden = overflow
            guard !overflow else { continue }
            item.frame = NSRect(x: gx, y: 3, width: width, height: h)
            gx += width + gap
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(Theme.toolbar, in: bounds)
        if groupRect.width > 0 {
            let path = NSBezierPath(roundedRect: groupRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            Theme.gradient([Theme.rgb(236, 244, 253), Theme.rgb(206, 224, 246)], in: path)
            Theme.toolbarLine.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        if let logo = Icons.brand {
            logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                      hints: [.interpolation: NSImageInterpolation.high])
        }
        Theme.toolbarLine.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

final class NavBar: FlippedView {
    let welcome = ChromeButton(title: "Welcome", symbol: "house.fill")
    let back = ChromeButton(symbol: "chevron.left")
    let forward = ChromeButton(symbol: "chevron.right")
    let reload = ChromeButton(symbol: "arrow.clockwise")
    let favorite = ChromeButton(symbol: "heart")
    let address = ActionTextField(placeholder: "Type a Keyword or Web Address here and click Go")
    let go = ChromeButton(title: "Go", prominent: true)
    let search = ChromeButton(title: "Search", symbol: "magnifyingglass")
    var isFavorite = false {
        didSet {
            guard isFavorite != oldValue else { return }
            favorite.symbol = Icons.symbol(isFavorite ? "heart.fill" : "heart", size: 11,
                                           colors: [isFavorite ? Theme.rgb(204, 40, 40) : Theme.aolBlue])
            favorite.toolTip = isFavorite ? "In your Favorite Places" : "Add to Favorites"
            favorite.needsDisplay = true
        }
    }
    var isLoading = false { didSet { reload.symbol = Icons.symbol(isLoading ? "xmark" : "arrow.clockwise", size: 11, colors: [Theme.aolBlue]); reload.needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [welcome, back, forward, reload, favorite, address, go, search].forEach(addSubview)
        back.toolTip = "Back"
        forward.toolTip = "Forward"
        favorite.toolTip = "Add to Favorites"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h: CGFloat = 22, y = (bounds.height - h) / 2
        var x: CGFloat = 8
        for b in [welcome, back, forward, reload, favorite] {
            b.frame = NSRect(x: x, y: y, width: b.preferredWidth, height: h)
            x = b.frame.maxX + (b === welcome ? 10 : 3)
        }
        let right = bounds.width - 8
        search.frame = NSRect(x: right - search.preferredWidth, y: y, width: search.preferredWidth, height: h)
        go.frame = NSRect(x: search.frame.minX - 6 - 38, y: y, width: 38, height: h)
        address.frame = NSRect(x: x + 7, y: y, width: go.frame.minX - x - 13, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(Theme.navBar, in: bounds)
        Theme.toolbarLine.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

final class StatusBar: FlippedView {
    var status = "" { didSet { needsDisplay = true } }
    var screenName = "" { didSet { needsDisplay = true } }
    private var timer: Timer?
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        Theme.chromeShade.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        drawText(status, font: Theme.ui(11), color: Theme.text, in: NSRect(x: 8, y: 0, width: bounds.width * 0.6, height: bounds.height))
        let right = screenName.isEmpty ? clock.string(from: Date()) : "\(screenName)    \(clock.string(from: Date()))"
        drawText(right, font: Theme.ui(11), color: Theme.text,
                 in: NSRect(x: bounds.width - 308, y: 0, width: 300, height: bounds.height), align: .right)
    }
}

/// The full-screen AOL frame. Top to bottom: title bar, menu row, toolbar, nav bar, desktop, status bar.
final class ShellView: FlippedView {
    let titleBar = AppTitleBar()
    let menuRow = MenuRow()
    let toolbar = ToolbarView()
    let navBar = NavBar()
    let desktop = DesktopView()
    let statusBar = StatusBar()
    let framed: Bool

    init(framed: Bool) {
        self.framed = framed
        super.init(frame: .zero)
        [titleBar, menuRow, toolbar, navBar, desktop, statusBar].forEach(addSubview)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b: CGFloat = framed ? 3 : 0
        let w = bounds.width - 2 * b
        var y = b
        titleBar.frame = NSRect(x: b, y: y, width: w, height: 30); y += 30
        menuRow.frame = NSRect(x: b, y: y, width: w, height: 22); y += 22
        toolbar.frame = NSRect(x: b, y: y, width: w, height: 58); y += 58
        navBar.frame = NSRect(x: b, y: y, width: w, height: 30); y += 30
        let statusHeight: CGFloat = 22
        statusBar.frame = NSRect(x: b, y: bounds.height - b - statusHeight, width: w, height: statusHeight)
        desktop.frame = NSRect(x: b, y: y, width: w, height: statusBar.frame.minY - y)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.frameActive.setFill()
        bounds.fill()
    }

    func setSignedOn(_ signedOn: Bool) {
        for item in toolbar.leftItems + toolbar.groupItems {
            item.isEnabled = signedOn
        }
        toolbar.customize.isEnabled = signedOn
        toolbar.nowPlaying.isEnabled = signedOn
        toolbar.needsLayout = true
        [navBar.welcome, navBar.back, navBar.forward, navBar.reload, navBar.favorite, navBar.go, navBar.search].forEach { $0.isEnabled = signedOn }
        navBar.address.isEnabled = signedOn
    }
}
