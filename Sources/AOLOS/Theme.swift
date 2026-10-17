import AppKit
import WebKit

enum Theme {
    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    /// A color that follows the drawing appearance, so the dark app theme can swap it.
    static func pair(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static let titleActive = [rgb(9, 97, 237), rgb(0, 72, 214), rgb(0, 61, 196)]
    static let titleInactive = [pair(rgb(140, 166, 229), rgb(70, 86, 128)), pair(rgb(118, 143, 214), rgb(56, 70, 110))]
    static let titleAttention = [rgb(255, 178, 66), rgb(232, 122, 18)]
    static let frameActive = rgb(0, 60, 190)
    static let frameInactive = pair(rgb(122, 150, 223), rgb(60, 74, 112))

    static let chrome = pair(rgb(236, 233, 216), rgb(48, 48, 52))
    static let chromeShade = pair(rgb(172, 168, 153), rgb(84, 84, 90))
    static let menuBar = pair(rgb(250, 251, 253), rgb(36, 37, 40))
    static let toolbar = [pair(rgb(255, 255, 255), rgb(58, 60, 66)), pair(rgb(222, 234, 248), rgb(40, 42, 48))]
    static let navBar = [pair(rgb(226, 237, 250), rgb(50, 54, 62)), pair(rgb(198, 218, 242), rgb(38, 42, 50))]
    static let toolbarLine = pair(rgb(150, 176, 214), rgb(72, 82, 102))
    static let desktop = [pair(rgb(110, 146, 196), rgb(22, 32, 52)), pair(rgb(180, 202, 230), rgb(44, 58, 84))]
    static let hover = rgb(49, 106, 197)
    /// List, chat and mail backgrounds.
    static let paper = pair(.white, rgb(30, 31, 34))

    static let aolBlue = pair(rgb(0, 84, 166), rgb(110, 170, 240))
    static let text = pair(rgb(20, 20, 20), rgb(228, 228, 230))
    static let mutedText = pair(rgb(90, 90, 90), rgb(160, 160, 166))

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

/// Dark mode for web pages, and the experimental dark theme for AOL-OS itself.
@MainActor
enum Appearance {
    private(set) static var darkWeb = false
    private static let webViews = NSHashTable<WKWebView>.weakObjects()

    /// Web pages see `prefers-color-scheme: dark` when their view's appearance is dark.
    static func track(_ webView: WKWebView) {
        webViews.add(webView)
        webView.appearance = NSAppearance(named: darkWeb ? .darkAqua : .aqua)
    }

    static func apply(darkWeb: Bool, darkApp: Bool) {
        self.darkWeb = darkWeb
        NSApp.appearance = NSAppearance(named: darkApp ? .darkAqua : .aqua)
        for webView in webViews.allObjects { webView.appearance = NSAppearance(named: darkWeb ? .darkAqua : .aqua) }
        for window in NSApp.windows { window.contentView.map(redraw) }
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }
}

enum Icons {
    /// Branding/titlebar-icon.png when present, otherwise a plain triangle. The artwork is not in the repository.
    static let brand: NSImage? = AppPaths.brandingImage("titlebar-icon.png")

    static func brandOrTriangle(size: CGFloat = 12) -> NSImage? {
        brand ?? symbol("triangle.fill", size: size, colors: [.white])
    }

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
