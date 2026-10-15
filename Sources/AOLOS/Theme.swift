import AppKit

enum Theme {
    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    static let titleActive = [rgb(18, 36, 132), rgb(12, 28, 112)]
    static let titleInactive = [rgb(128, 140, 170), rgb(112, 124, 156)]
    static let titleAttention = [rgb(255, 178, 66), rgb(232, 122, 18)]
    static let frameActive = rgb(10, 26, 104)
    static let frameInactive = rgb(120, 132, 162)

    static let chrome = rgb(236, 233, 216)
    static let chromeShade = rgb(172, 168, 153)
    static let menuBar = rgb(250, 251, 253)
    static let toolbar = [rgb(255, 255, 255), rgb(222, 234, 248)]
    static let navBar = [rgb(226, 237, 250), rgb(198, 218, 242)]
    static let toolbarLine = rgb(150, 176, 214)
    static let desktop = [rgb(110, 146, 196), rgb(180, 202, 230)]
    static let hover = rgb(49, 106, 197)

    static let aolBlue = rgb(0, 84, 166)
    static let text = rgb(20, 20, 20)
    static let mutedText = rgb(90, 90, 90)

    static func ui(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "Tahoma-Bold" : "Tahoma", size: size)
            ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
    }

    static func caption(_ size: CGFloat) -> NSFont {
        NSFont(name: "TrebuchetMS-Bold", size: size) ?? .boldSystemFont(ofSize: size)
    }

    static func gradient(_ colors: [NSColor], in rect: NSRect) {
        NSGradient(colors: colors)?.draw(in: rect, angle: 90)
    }

    static func gradient(_ colors: [NSColor], in path: NSBezierPath) {
        NSGradient(colors: colors)?.draw(in: path, angle: 90)
    }
}

enum Icons {
    static func symbol(_ name: String, size: CGFloat = 13, colors: [NSColor]? = nil) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        var config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        if let colors { config = config.applying(.init(paletteColors: colors)) }
        return base.withSymbolConfiguration(config)
    }
}

/// Every chrome view in AOL-OS uses top-left origin coordinates.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class GradientView: FlippedView {
    var colors: [NSColor] { didSet { needsDisplay = true } }
    var bottomLine: NSColor?

    init(colors: [NSColor], bottomLine: NSColor? = nil) {
        self.colors = colors
        self.bottomLine = bottomLine
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient(colors, in: bounds)
        if let bottomLine {
            bottomLine.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }
}

func drawText(_ string: String, font: NSFont, color: NSColor, in rect: NSRect,
              align: NSTextAlignment = .left, shadow: Bool = false) {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineBreakMode = .byTruncatingTail
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
    if shadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.55)
        s.shadowOffset = NSSize(width: 1, height: -1)
        s.shadowBlurRadius = 0
        attrs[.shadow] = s
    }
    let height = font.ascender - font.descender
    let r = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height + 2)
    (string as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
}
