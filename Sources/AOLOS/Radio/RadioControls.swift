import AppKit

@MainActor
enum ImageLoader {
    private static var cache: [URL: NSImage] = [:]

    static func load(_ url: URL?, into view: NSImageView) {
        guard let url else {
            view.image = nil
            return
        }
        if let cached = cache[url] {
            view.image = cached
            return
        }
        view.toolTip = url.absoluteString
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
            cache[url] = image
            if view.toolTip == url.absoluteString { view.image = image }
        }
    }
}

/// Rounded panel with the blue AOL Radio header bar.
final class RadioPanel: FlippedView {
    let title: String
    let content = FlippedView()
    var headerAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let headerAccessory { addSubview(headerAccessory) }
            needsLayout = true
        }
    }
    static let headerHeight: CGFloat = 22

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        content.frame = NSRect(x: 2, y: Self.headerHeight + 1, width: bounds.width - 4, height: bounds.height - Self.headerHeight - 3)
        if let accessory = headerAccessory {
            let w = (accessory as? ChromeButton)?.preferredWidth ?? accessory.fittingSize.width
            accessory.frame = NSRect(x: bounds.width - w - 6, y: 2, width: w, height: Self.headerHeight - 4)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        Theme.paper.setFill()
        outline.fill()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        Theme.gradient([Theme.rgb(92, 140, 214), Theme.rgb(38, 86, 170)], in: NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight))
        NSGraphicsContext.restoreGraphicsState()
        Theme.rgb(52, 98, 176).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        drawText(title, font: Theme.ui(12, bold: true), color: .white,
                 in: NSRect(x: 8, y: 0, width: bounds.width - 16, height: Self.headerHeight), shadow: true)
    }
}

/// Underlined blue text that acts like a web link.
final class LinkLabel: PressableView {
    var text = "" { didSet { needsDisplay = true; toolTip = text } }
    var bold = false

    override func draw(_ dirtyRect: NSRect) {
        let color = isEnabled && action != nil ? Theme.rgb(20, 70, 170) : Theme.text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.ui(12, bold: bold),
            .foregroundColor: isHovered ? Theme.rgb(200, 60, 20) : color,
            .underlineStyle: action != nil ? NSUnderlineStyle.single.rawValue : 0,
        ]
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        var attrs = attributes
        attrs[.paragraphStyle] = style
        (text as NSString).draw(in: bounds, withAttributes: attrs)
    }

    override func resetCursorRects() {
        if action != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// Round transport button: a red stop square, or a green play triangle that turns into pause.
final class TransportButton: PressableView {
    enum Kind { case stop, play, pause }
    var kind: Kind { didSet { needsDisplay = true } }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        var colors = [Theme.rgb(255, 255, 255), Theme.rgb(214, 210, 196)]
        if isPressed { colors.reverse() } else if isHovered { colors = [Theme.rgb(255, 255, 255), Theme.rgb(236, 232, 214)] }
        Theme.gradient(colors, in: circle)
        Theme.chromeShade.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()

        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let s = bounds.width * 0.18
        switch kind {
        case .stop:
            Theme.rgb(200, 30, 30).setFill()
            NSRect(x: c.x - s, y: c.y - s, width: s * 2, height: s * 2).fill()
        case .play:
            Theme.rgb(30, 150, 50).setFill()
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: c.x - s * 0.8, y: c.y - s * 1.2))
            tri.line(to: NSPoint(x: c.x + s * 1.3, y: c.y))
            tri.line(to: NSPoint(x: c.x - s * 0.8, y: c.y + s * 1.2))
            tri.close()
            tri.fill()
        case .pause:
            Theme.rgb(30, 150, 50).setFill()
            NSRect(x: c.x - s, y: c.y - s * 1.1, width: s * 0.7, height: s * 2.2).fill()
            NSRect(x: c.x + s * 0.3, y: c.y - s * 1.1, width: s * 0.7, height: s * 2.2).fill()
        }
    }
}

final class ProgressStrip: FlippedView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        Theme.rgb(232, 236, 244).setFill()
        track.fill()
        let filled = NSRect(x: 0, y: 0, width: bounds.width * max(0, min(1, fraction)), height: bounds.height)
        Theme.gradient([Theme.rgb(120, 170, 240), Theme.rgb(40, 96, 200)], in: NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3))
        Theme.chromeShade.setStroke()
        track.stroke()
    }
}

/// One row of the station list. Categories draw a plus or minus box. Stations draw a blue diamond.
final class StationRowView: FlippedView {
    enum Row {
        case category(SpotifyService.Category, expanded: Bool, count: Int)
        case station(RadioStation)
    }

    var row: Row = .station(RadioStation(title: "", subtitle: "")) { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        switch row {
        case .category(let category, let expanded, let count):
            let box = NSRect(x: 4, y: (bounds.height - 9) / 2, width: 9, height: 9)
            Theme.paper.setFill()
            box.fill()
            Theme.mutedText.setStroke()
            NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
            Theme.text.setFill()
            NSRect(x: box.minX + 2, y: box.midY - 0.5, width: 5, height: 1).fill()
            if !expanded { NSRect(x: box.midX - 0.5, y: box.minY + 2, width: 1, height: 5).fill() }
            let label = count > 0 || category == .search ? category.rawValue : "\(category.rawValue) (empty)"
            drawText(label, font: Theme.ui(12, bold: true), color: Theme.text,
                     in: NSRect(x: 18, y: 0, width: bounds.width - 20, height: bounds.height))
        case .station(let station):
            let textWidth = (station.title as NSString).size(withAttributes: [.font: Theme.ui(12)]).width
            if isCurrent {
                Theme.rgb(232, 240, 150).setFill()
                NSRect(x: 30, y: 1, width: min(textWidth + 8, bounds.width - 32), height: bounds.height - 2).fill()
                Theme.rgb(150, 160, 60).setStroke()
                NSBezierPath(rect: NSRect(x: 30.5, y: 1.5, width: min(textWidth + 7, bounds.width - 33), height: bounds.height - 3)).stroke()
            }
            let d = NSBezierPath()
            let c = NSPoint(x: 23, y: bounds.midY)
            d.move(to: NSPoint(x: c.x, y: c.y - 3.5))
            d.line(to: NSPoint(x: c.x + 3.5, y: c.y))
            d.line(to: NSPoint(x: c.x, y: c.y + 3.5))
            d.line(to: NSPoint(x: c.x - 3.5, y: c.y))
            d.close()
            Theme.rgb(30, 70, 160).setFill()
            d.fill()
            drawText(station.title, font: Theme.ui(12), color: Theme.rgb(20, 40, 110),
                     in: NSRect(x: 34, y: 0, width: bounds.width - 36, height: bounds.height))
        }
    }
}
