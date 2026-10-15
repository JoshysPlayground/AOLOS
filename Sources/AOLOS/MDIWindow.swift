import AppKit

final class MDITitleBar: FlippedView {
    enum State { case active, inactive, attention }

    var title = "" { didSet { needsDisplay = true } }
    var icon: NSImage?
    var state: State = .active { didSet { needsDisplay = true } }
    let minButton = CaptionButton(kind: .minimize)
    let maxButton = CaptionButton(kind: .maximize)
    let closeButton = CaptionButton(kind: .close)
    weak var owner: MDIWindow?

    private var dragStart: NSPoint?
    private var originStart: NSPoint = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        [minButton, maxButton, closeButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let size = bounds.height - 5
        var x = bounds.width - size - 3
        for button in [closeButton, maxButton, minButton] where !button.isHidden {
            button.frame = NSRect(x: x, y: 2.5, width: size, height: size)
            x -= size + 2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor]
        switch state {
        case .active: colors = Theme.titleActive
        case .inactive: colors = Theme.titleInactive
        case .attention: colors = Theme.titleAttention
        }
        Theme.gradient(colors, in: bounds)
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        var x: CGFloat = 6
        if let icon {
            icon.draw(in: NSRect(x: x, y: (bounds.height - 15) / 2, width: 15, height: 15),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 21
        }
        let buttonsWidth = CGFloat([minButton, maxButton, closeButton].filter { !$0.isHidden }.count) * (bounds.height - 3)
        drawText(title, font: Theme.caption(13), color: .white,
                 in: NSRect(x: x, y: 0, width: bounds.width - x - buttonsWidth - 8, height: bounds.height), shadow: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner, let desktop = owner.superview else { return }
        if event.clickCount == 2, !owner.maxButton.isHidden {
            owner.toggleMaximize()
            return
        }
        owner.activate()
        guard !owner.isMaximized else { return }
        dragStart = desktop.convert(event.locationInWindow, from: nil)
        originStart = owner.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let owner, let desktop = owner.superview, let dragStart else { return }
        let p = desktop.convert(event.locationInWindow, from: nil)
        var origin = NSPoint(x: originStart.x + p.x - dragStart.x, y: originStart.y + p.y - dragStart.y)
        origin.y = min(max(0, origin.y), desktop.bounds.height - 30)
        origin.x = min(max(-owner.frame.width + 100, origin.x), desktop.bounds.width - 100)
        owner.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }
}

/// A child window inside the desktop. Content is any NSView, usually a WebPane.
final class MDIWindow: FlippedView {
    static let border: CGFloat = 4
    static let titleHeight: CGFloat = 26

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    let titleBar = MDITitleBar()
    let content: NSView
    weak var desktop: DesktopView?
    weak var focusView: NSView?
    var onClose: (() -> Void)?
    var minSize = NSSize(width: 320, height: 200)
    var zIndex = 0
    private(set) var isMaximized = false
    private var restoreFrame = NSRect.zero

    private var resizeEdges: Edges = []
    private var resizeStart = NSPoint.zero
    private var frameStart = NSRect.zero

    var title: String {
        get { titleBar.title }
        set { titleBar.title = newValue; desktop?.windowsChanged() }
    }

    var icon: NSImage? { titleBar.icon }
    var maxButton: CaptionButton { titleBar.maxButton }

    var isActive = false {
        didSet {
            if isActive { attention = false }
            updateTitleState()
            needsDisplay = true
        }
    }

    var attention = false { didSet { updateTitleState() } }

    var closable = true {
        didSet { titleBar.closeButton.isHidden = !closable; titleBar.needsLayout = true }
    }

    var minimizable = true {
        didSet { titleBar.minButton.isHidden = !minimizable; titleBar.needsLayout = true }
    }

    var resizable = true {
        didSet { titleBar.maxButton.isHidden = !resizable; titleBar.needsLayout = true; window?.invalidateCursorRects(for: self) }
    }

    init(title: String, icon: NSImage?, content: NSView) {
        self.content = content
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 560))
        titleBar.title = title
        titleBar.icon = icon
        titleBar.owner = self
        addSubview(content)
        addSubview(titleBar)
        titleBar.minButton.action = { [weak self] in self.map { $0.desktop?.minimize($0) } }
        titleBar.maxButton.action = { [weak self] in self?.toggleMaximize() }
        titleBar.closeButton.action = { [weak self] in self.map { $0.desktop?.close($0) } }
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let b = isMaximized ? 0 : Self.border
        titleBar.frame = NSRect(x: b, y: b, width: bounds.width - 2 * b, height: Self.titleHeight)
        content.frame = NSRect(x: b, y: b + Self.titleHeight, width: bounds.width - 2 * b,
                               height: max(0, bounds.height - Self.titleHeight - 2 * b))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.rgb(212, 208, 200).setFill()
        bounds.fill()
        Theme.rgb(64, 64, 64).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        NSColor.white.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5)).stroke()
    }

    private func updateTitleState() {
        titleBar.state = attention && !isActive ? .attention : (isActive ? .active : .inactive)
    }

    func activate() { desktop?.activate(self) }

    func toggleMaximize() {
        guard let desktop, resizable else { return }
        if isMaximized {
            isMaximized = false
            autoresizingMask = []
            frame = restoreFrame
            titleBar.maxButton.kind = .maximize
        } else {
            restoreFrame = frame
            isMaximized = true
            frame = desktop.bounds
            autoresizingMask = [.width, .height]
            titleBar.maxButton.kind = .restore
        }
        needsLayout = true
        window?.invalidateCursorRects(for: self)
        desktop.activate(self)
    }

    func setMaximizedFrame(_ rect: NSRect) {
        if isMaximized { toggleMaximize() }
        frame = rect
    }

    private func edges(at p: NSPoint) -> Edges {
        let g = Self.border + 1
        var e: Edges = []
        if p.x < g { e.insert(.left) }
        if p.x > bounds.width - g { e.insert(.right) }
        if p.y < g { e.insert(.top) }
        if p.y > bounds.height - g { e.insert(.bottom) }
        return e
    }

    override func resetCursorRects() {
        guard resizable, !isMaximized else { return }
        let g = Self.border + 1
        addCursorRect(NSRect(x: 0, y: 0, width: g, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - g, y: 0, width: g, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: g), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.height - g, width: bounds.width, height: g), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        activate()
        guard resizable, !isMaximized, let sv = superview else { return }
        resizeEdges = edges(at: convert(event.locationInWindow, from: nil))
        resizeStart = sv.convert(event.locationInWindow, from: nil)
        frameStart = frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard !resizeEdges.isEmpty, let sv = superview else { return }
        let p = sv.convert(event.locationInWindow, from: nil)
        let dx = p.x - resizeStart.x, dy = p.y - resizeStart.y
        var f = frameStart
        if resizeEdges.contains(.right) { f.size.width = max(minSize.width, frameStart.width + dx) }
        if resizeEdges.contains(.left) {
            let w = max(minSize.width, frameStart.width - dx)
            f.origin.x = frameStart.maxX - w
            f.size.width = w
        }
        if resizeEdges.contains(.bottom) { f.size.height = max(minSize.height, frameStart.height + dy) }
        if resizeEdges.contains(.top) {
            let h = max(minSize.height, frameStart.height - dy)
            f.origin.y = max(0, frameStart.maxY - h)
            f.size.height = frameStart.maxY - f.origin.y
        }
        frame = f
    }

    override func mouseUp(with event: NSEvent) {
        resizeEdges = []
    }
}
