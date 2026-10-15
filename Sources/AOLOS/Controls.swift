import AppKit

/// Base for custom-drawn clickable chrome. Fires `action` on mouse up inside the view.
class PressableView: FlippedView {
    var action: (() -> Void)?
    var isEnabled = true { didSet { needsDisplay = true } }
    var isHovered = false
    var isPressed = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        needsDisplay = true
        if wasPressed, isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) {
            action?()
        }
    }
}

final class CaptionButton: PressableView {
    enum Kind { case minimize, maximize, restore, close }
    var kind: Kind { didSet { needsDisplay = true } }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 21, height: 21))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        var colors = kind == .close
            ? [Theme.rgb(236, 128, 96), Theme.rgb(204, 60, 28)]
            : [Theme.rgb(96, 156, 252), Theme.rgb(28, 88, 222)]
        if isPressed {
            colors = colors.map { $0.blended(withFraction: 0.25, of: .black) ?? $0 }
        } else if isHovered {
            colors = colors.map { $0.blended(withFraction: 0.2, of: .white) ?? $0 }
        }
        Theme.gradient(colors, in: path)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1
        path.stroke()

        NSColor.white.set()
        let w = bounds.width, h = bounds.height
        switch kind {
        case .minimize:
            NSRect(x: w * 0.25, y: h * 0.66, width: w * 0.38, height: 2.5).fill()
        case .maximize:
            let box = NSRect(x: w * 0.24, y: h * 0.24, width: w * 0.52, height: h * 0.5)
            NSBezierPath(rect: box).stroke()
            NSRect(x: box.minX, y: box.minY, width: box.width, height: 2.5).fill()
        case .restore:
            let back = NSRect(x: w * 0.36, y: h * 0.2, width: w * 0.4, height: h * 0.36)
            let front = NSRect(x: w * 0.22, y: h * 0.4, width: w * 0.4, height: h * 0.36)
            NSBezierPath(rect: back).stroke()
            NSRect(x: back.minX, y: back.minY, width: back.width, height: 2).fill()
            Theme.rgb(28, 88, 222).setFill()
            front.fill()
            NSColor.white.set()
            NSBezierPath(rect: front).stroke()
            NSRect(x: front.minX, y: front.minY, width: front.width, height: 2).fill()
        case .close:
            let x = NSBezierPath()
            x.lineWidth = 2
            x.move(to: NSPoint(x: w * 0.3, y: h * 0.3))
            x.line(to: NSPoint(x: w * 0.7, y: h * 0.7))
            x.move(to: NSPoint(x: w * 0.7, y: h * 0.3))
            x.line(to: NSPoint(x: w * 0.3, y: h * 0.7))
            x.stroke()
        }
    }
}

/// Rounded beige button used in the nav bar and dialogs.
final class ChromeButton: PressableView {
    var title: String { didSet { needsDisplay = true } }
    var symbol: NSImage?
    var prominent = false

    init(title: String = "", symbol: String? = nil, prominent: Bool = false, action: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol.flatMap { Icons.symbol($0, size: 11, colors: [Theme.aolBlue]) }
        self.prominent = prominent
        super.init(frame: .zero)
        self.action = action
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredWidth: CGFloat {
        let textWidth = title.isEmpty ? 0 : (title as NSString).size(withAttributes: [.font: Theme.ui(11, bold: prominent)]).width
        let iconWidth: CGFloat = symbol == nil ? 0 : 16
        return max(26, textWidth + iconWidth + (title.isEmpty ? 10 : 20))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        var colors = prominent
            ? [Theme.rgb(255, 234, 140), Theme.rgb(245, 196, 40)]
            : [Theme.rgb(255, 255, 255), Theme.rgb(226, 222, 206)]
        if isPressed {
            colors = colors.map { $0.blended(withFraction: 0.15, of: .black) ?? $0 }
        } else if isHovered {
            colors = [Theme.rgb(255, 250, 230), Theme.rgb(250, 226, 160)]
        }
        Theme.gradient(colors, in: path)
        Theme.chromeShade.setStroke()
        path.stroke()

        let alpha: CGFloat = isEnabled ? 1 : 0.4
        var x = bounds.midX - (preferredWidth - (title.isEmpty ? 10 : 20)) / 2
        if let symbol {
            symbol.draw(in: NSRect(x: x, y: bounds.midY - 6, width: 12, height: 12),
                        from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            x += 16
        }
        if !title.isEmpty {
            drawText(title, font: Theme.ui(11, bold: prominent), color: Theme.text.withAlphaComponent(alpha),
                     in: NSRect(x: x, y: 0, width: bounds.maxX - x, height: bounds.height))
        }
    }
}

/// Icon-over-label toolbar button. Uses Branding/Toolbar/<name>-active.png and -inactive.png when present,
/// and a tinted SF Symbol otherwise.
final class ToolbarButton: PressableView {
    let title: String
    var name: String { didSet { loadImages() } }
    var available = true { didSet { needsDisplay = true } }
    private let symbol: String
    private let colors: [NSColor]
    private var activeImage: NSImage?
    private var inactiveImage: NSImage?

    init(title: String, name: String, symbol: String, colors: [NSColor], action: (() -> Void)? = nil) {
        self.title = title
        self.name = name
        self.symbol = symbol
        self.colors = colors
        super.init(frame: .zero)
        self.action = action
        loadImages()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    private var isLive: Bool { isEnabled && available }

    private func loadImages() {
        activeImage = AppPaths.brandingImage("Toolbar/\(name)-active.png") ?? Icons.symbol(symbol, size: 22, colors: colors)
        inactiveImage = AppPaths.brandingImage("Toolbar/\(name)-inactive.png")
            ?? Icons.symbol(symbol, size: 22, colors: [Theme.rgb(160, 160, 160)])
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isLive else { return }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isLive && (isHovered || isPressed) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
            Theme.gradient(isPressed ? [Theme.rgb(196, 216, 242), Theme.rgb(226, 238, 252)]
                                     : [Theme.rgb(255, 255, 255), Theme.rgb(220, 234, 252)], in: path)
            Theme.toolbarLine.setStroke()
            path.stroke()
        }
        if let image = isLive ? activeImage : inactiveImage {
            let side: CGFloat = min(32, bounds.height - 20)
            let rect = NSRect(x: bounds.midX - side / 2, y: 3, width: side, height: side)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high])
        }
        drawText(title, font: Theme.ui(10.5, bold: true),
                 color: isLive ? Theme.rgb(24, 40, 96) : Theme.rgb(150, 156, 170),
                 in: NSRect(x: 0, y: bounds.height - 16, width: bounds.width, height: 14), align: .center)
    }
}

/// Text item in the menu row that drops down an NSMenu built on demand.
final class MenuRowItem: PressableView {
    let title: String
    let buildMenu: () -> NSMenu

    init(title: String, buildMenu: @escaping () -> NSMenu) {
        self.title = title
        self.buildMenu = buildMenu
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredWidth: CGFloat {
        (title as NSString).size(withAttributes: [.font: Theme.ui(12)]).width + 18
    }

    override func mouseDown(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        let menu = buildMenu()
        menu.font = Theme.ui(12)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
        isHovered = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Theme.hover.setFill()
            bounds.insetBy(dx: 1, dy: 2).fill()
        }
        let attributed = NSMutableAttributedString(string: title, attributes: [
            .font: Theme.ui(12),
            .foregroundColor: isHovered ? NSColor.white : Theme.text,
        ])
        attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 1))
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
