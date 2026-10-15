import AppKit

/// Placeholder for a minimized MDI window, shown along the bottom of the desktop.
final class TrayChip: PressableView {
    weak var target: MDIWindow?

    init(target: MDIWindow) {
        self.target = target
        super.init(frame: .zero)
        toolTip = target.title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        let colors = target?.attention == true ? Theme.titleAttention
            : (isHovered ? Theme.titleActive : Theme.titleInactive)
        Theme.gradient(colors, in: path)
        Theme.frameActive.setStroke()
        path.stroke()
        var x: CGFloat = 5
        if let icon = target?.icon {
            icon.draw(in: NSRect(x: x, y: (bounds.height - 13) / 2, width: 13, height: 13),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 18
        }
        drawText(target?.title ?? "", font: Theme.caption(11), color: .white,
                 in: NSRect(x: x, y: 0, width: bounds.width - x - 6, height: bounds.height), shadow: true)
    }
}

/// MDI client area. Owns stacking, activation, minimize, cascade and tile.
final class DesktopView: FlippedView {
    private(set) var windows: [MDIWindow] = []
    private var chips: [ObjectIdentifier: TrayChip] = [:]
    private var topZ = 0
    private var cascadeIndex = 0
    private var clickMonitor: Any?
    var onChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizesSubviews = true
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.activateWindow(under: event)
            return event
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(Theme.desktop, in: bounds)
    }

    override func layout() {
        super.layout()
        layoutChips()
    }

    var activeWindow: MDIWindow? { windows.first { $0.isActive && !$0.isHidden } }
    var visibleWindows: [MDIWindow] { windows.filter { !$0.isHidden }.sorted { $0.zIndex < $1.zIndex } }

    /// Clicks inside a web view never reach MDIWindow.mouseDown, so activation is driven from a local event monitor.
    private func activateWindow(under event: NSEvent) {
        guard event.window === window else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        if chips.values.contains(where: { $0.frame.contains(p) }) { return }
        if let hit = visibleWindows.last(where: { $0.frame.contains(p) }), !hit.isActive {
            activate(hit)
        }
    }

    func add(_ w: MDIWindow, size: NSSize? = nil, centered: Bool = false, minimized: Bool = false) {
        w.desktop = self
        windows.append(w)
        addSubview(w)
        let s = size ?? NSSize(width: min(bounds.width * 0.72, 1100), height: min(bounds.height * 0.8, 760))
        if centered {
            w.frame = NSRect(x: max(0, (bounds.width - s.width) / 2), y: max(0, (bounds.height - s.height) / 2.4),
                             width: s.width, height: s.height)
        } else {
            w.frame = nextCascadeRect(size: s)
        }
        if minimized {
            minimize(w)
        } else {
            activate(w)
        }
    }

    func activate(_ w: MDIWindow) {
        if w.isHidden {
            restore(w)
            return
        }
        topZ += 1
        w.zIndex = topZ
        restack()
        for x in windows { x.isActive = (x === w) }
        if let focus = w.focusView ?? w.content.subviews.first {
            window?.makeFirstResponder(focus)
        }
        windowsChanged()
    }

    func minimize(_ w: MDIWindow) {
        guard w.minimizable else { return }
        w.isHidden = true
        w.isActive = false
        let chip = TrayChip(target: w)
        chip.action = { [weak self, weak w] in
            if let w { self?.restore(w) }
        }
        chips[ObjectIdentifier(w)] = chip
        addSubview(chip)
        layoutChips()
        restack()
        activateTopmost()
    }

    func restore(_ w: MDIWindow) {
        chips.removeValue(forKey: ObjectIdentifier(w))?.removeFromSuperview()
        w.isHidden = false
        layoutChips()
        activate(w)
    }

    func close(_ w: MDIWindow) {
        chips.removeValue(forKey: ObjectIdentifier(w))?.removeFromSuperview()
        w.removeFromSuperview()
        windows.removeAll { $0 === w }
        w.onClose?()
        layoutChips()
        activateTopmost()
    }

    func closeAll(includingPinned: Bool = false) {
        for w in windows where w.closable || includingPinned { close(w) }
    }

    func cycle() {
        let visible = visibleWindows
        guard visible.count > 1, let bottom = visible.first else { return }
        activate(bottom)
    }

    func cascade() {
        cascadeIndex = 0
        let size = NSSize(width: min(bounds.width * 0.7, 1100), height: min(bounds.height * 0.75, 740))
        for w in visibleWindows { w.setMaximizedFrame(nextCascadeRect(size: size)) }
        activateTopmost()
    }

    func tile() {
        let visible = visibleWindows
        guard !visible.isEmpty else { return }
        let cols = Int(ceil(sqrt(Double(visible.count))))
        let rows = Int(ceil(Double(visible.count) / Double(cols)))
        let w = bounds.width / CGFloat(cols)
        let h = (bounds.height - (chips.isEmpty ? 0 : 30)) / CGFloat(rows)
        for (i, win) in visible.enumerated() {
            let rect = NSRect(x: CGFloat(i % cols) * w, y: CGFloat(i / cols) * h, width: w, height: h)
            win.setMaximizedFrame(rect.integral)
        }
    }

    func windowsChanged() {
        chips.values.forEach { $0.needsDisplay = true }
        onChange?()
    }

    private func activateTopmost() {
        if let top = visibleWindows.last {
            activate(top)
        } else {
            windowsChanged()
        }
    }

    private func nextCascadeRect(size: NSSize) -> NSRect {
        let step: CGFloat = 26
        let i = CGFloat(cascadeIndex % 8)
        cascadeIndex += 1
        let width = min(size.width, max(320, bounds.width - 20))
        let height = min(size.height, max(200, bounds.height - 20))
        return NSRect(x: 14 + step * i, y: 10 + step * i, width: width, height: height)
    }

    private func layoutChips() {
        var x: CGFloat = 6
        for w in windows where w.isHidden {
            guard let chip = chips[ObjectIdentifier(w)] else { continue }
            chip.frame = NSRect(x: x, y: bounds.height - 28, width: 170, height: 23)
            x += 174
        }
    }

    private func restack() {
        sortSubviews(Self.zOrder, context: nil)
    }

    private static func zValue(_ view: NSView) -> Int {
        if view is TrayChip { return Int.max }
        if let w = view as? MDIWindow { return w.zIndex }
        return Int.min
    }

    private static let zOrder: @convention(c) (NSView, NSView, UnsafeMutableRawPointer?) -> ComparisonResult = { a, b, _ in
        let za = DesktopView.zValue(a), zb = DesktopView.zValue(b)
        if za == zb { return .orderedSame }
        return za < zb ? .orderedAscending : .orderedDescending
    }
}
