import AppKit

final class AppTitleBar: FlippedView {
    let minButton = CaptionButton(kind: .minimize)
    let closeButton = CaptionButton(kind: .close)
    var title = "AOL-OS 9.0 Optimized SE" { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(minButton)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let s = bounds.height - 5
        closeButton.frame = NSRect(x: bounds.width - s - 4, y: 2.5, width: s, height: s)
        minButton.frame = NSRect(x: closeButton.frame.minX - s - 2, y: 2.5, width: s, height: s)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(Theme.titleActive, in: bounds)
        if let icon = Icons.symbol("triangle.fill", size: 12, colors: [.white]) {
            icon.draw(in: NSRect(x: 7, y: (bounds.height - 14) / 2, width: 14, height: 14),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawText(title, font: Theme.caption(13), color: .white,
                 in: NSRect(x: 27, y: 0, width: bounds.width - 100, height: bounds.height), shadow: true)
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
        Theme.chrome.setFill()
        bounds.fill()
    }
}

final class ToolbarView: FlippedView {
    var leftItems: [NSView] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; leftItems.forEach(addSubview); needsLayout = true } }
    var rightItems: [NSView] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; rightItems.forEach(addSubview); needsLayout = true } }
    static let itemWidth: CGFloat = 66

    override func layout() {
        super.layout()
        var x: CGFloat = 6
        for item in leftItems {
            item.frame = NSRect(x: x, y: 3, width: Self.itemWidth, height: bounds.height - 6)
            x += Self.itemWidth
        }
        x = bounds.width - 6
        for item in rightItems.reversed() {
            x -= Self.itemWidth
            item.frame = NSRect(x: x, y: 3, width: Self.itemWidth, height: bounds.height - 6)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(Theme.toolbar, in: bounds)
        if let last = leftItems.last {
            let groupRect = NSRect(x: 3, y: 2, width: last.frame.maxX - 1, height: bounds.height - 4)
            let path = NSBezierPath(roundedRect: groupRect, xRadius: 6, yRadius: 6)
            Theme.chromeShade.withAlphaComponent(0.5).setStroke()
            path.stroke()
        }
        Theme.chromeShade.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

final class NavBar: FlippedView {
    let welcome = ChromeButton(title: "Welcome", symbol: "house.fill")
    let back = ChromeButton(symbol: "chevron.left")
    let forward = ChromeButton(symbol: "chevron.right")
    let reload = ChromeButton(symbol: "arrow.clockwise")
    let address = ActionTextField(placeholder: "Type a Keyword or Web Address here and click Go")
    let go = ChromeButton(title: "Go", prominent: true)
    let search = ChromeButton(title: "Search", symbol: "magnifyingglass")
    var isLoading = false { didSet { reload.symbol = Icons.symbol(isLoading ? "xmark" : "arrow.clockwise", size: 11, colors: [Theme.aolBlue]); reload.needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [welcome, back, forward, reload, address, go, search].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h: CGFloat = 22, y = (bounds.height - h) / 2
        var x: CGFloat = 8
        for b in [welcome, back, forward, reload] {
            b.frame = NSRect(x: x, y: y, width: b.preferredWidth, height: h)
            x = b.frame.maxX + (b === welcome ? 10 : 3)
        }
        let right = bounds.width - 8
        search.frame = NSRect(x: right - search.preferredWidth, y: y, width: search.preferredWidth, height: h)
        go.frame = NSRect(x: search.frame.minX - 6 - 38, y: y, width: 38, height: h)
        address.frame = NSRect(x: x + 7, y: y, width: go.frame.minX - x - 13, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        Theme.chromeShade.setFill()
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
        titleBar.frame = NSRect(x: b, y: y, width: w, height: 28); y += 28
        menuRow.frame = NSRect(x: b, y: y, width: w, height: 22); y += 22
        toolbar.frame = NSRect(x: b, y: y, width: w, height: 62); y += 62
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
        for case let item as PressableView in toolbar.leftItems + toolbar.rightItems {
            item.isEnabled = signedOn
        }
        [navBar.welcome, navBar.back, navBar.forward, navBar.reload, navBar.go, navBar.search].forEach { $0.isEnabled = signedOn }
        navBar.address.isEnabled = signedOn
    }
}
