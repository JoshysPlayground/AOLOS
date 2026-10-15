import AppKit

struct SafetyItem {
    enum State { case on, off, notDetected, unknown }
    let label: String
    let state: State
}

/// Real security checks shown under "Safety on My Mac". Each runs a stock macOS command without admin rights.
enum MacSafety {
    static func check() async -> [SafetyItem] {
        await Task.detached {
            [
                SafetyItem(label: "FileVault Encryption", state: state(run("/usr/bin/fdesetup", ["status"]), on: "FileVault is On")),
                SafetyItem(label: "Firewall", state: state(
                    run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]), on: "enabled", off: .notDetected)),
                SafetyItem(label: "Gatekeeper", state: state(run("/usr/sbin/spctl", ["--status"]), on: "assessments enabled")),
                SafetyItem(label: "System Integrity", state: state(run("/usr/bin/csrutil", ["status"]), on: "status: enabled")),
            ]
        }.value
    }

    private static func state(_ output: String?, on marker: String, off: SafetyItem.State = .off) -> SafetyItem.State {
        guard let output else { return .unknown }
        return output.localizedCaseInsensitiveContains(marker) ? .on : off
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

/// Fully rounded gradient button, like Sign On and Sign On Options.
final class PillButton: PressableView {
    enum Style { case blue, green }
    var title: String { didSet { needsDisplay = true } }
    let style: Style

    init(title: String, style: Style, action: (() -> Void)? = nil) {
        self.title = title
        self.style = style
        super.init(frame: .zero)
        self.action = action
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        var colors: [NSColor]
        let border: NSColor
        let textColor: NSColor
        switch style {
        case .blue:
            colors = [Theme.rgb(212, 236, 250), Theme.rgb(140, 196, 232), Theme.rgb(118, 180, 222)]
            border = Theme.rgb(52, 110, 170)
            textColor = Theme.rgb(10, 40, 100)
        case .green:
            colors = [Theme.rgb(226, 250, 196), Theme.rgb(152, 222, 104), Theme.rgb(118, 200, 70)]
            border = Theme.rgb(60, 130, 40)
            textColor = Theme.rgb(20, 70, 10)
        }
        if isPressed { colors.reverse() } else if isHovered { colors = colors.map { $0.blended(withFraction: 0.15, of: .white) ?? $0 } }
        if !isEnabled { colors = colors.map { $0.blended(withFraction: 0.5, of: .white) ?? $0 } }
        Theme.gradient(colors, in: path)
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
        drawText(title, font: Theme.ui(12, bold: true), color: textColor.withAlphaComponent(isEnabled ? 1 : 0.5),
                 in: bounds, align: .center)
    }
}

/// The Sign On window from AOL 9.0: screen name and location, Sign On Options, and the two Safety panels.
final class SignOnView: FlippedView {
    var onSignOn: ((String, String) -> Void)?
    var onCancel: (() -> Void)?
    var onScreenNamesChanged: (([String]) -> Void)?
    var onToggleTouchID: (() -> Void)?
    var onToggleSounds: (() -> Void)?
    var onHelp: (() -> Void)?

    static let locations = ["Home (Broadband)", "Dial-Up (56K)"]

    private var screenNames: [String]
    private let namePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let locationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let optionsButton = PillButton(title: "Sign On Options", style: .blue)
    private let signOnButton = PillButton(title: "Sign On", style: .green)
    private let cancelButton = PillButton(title: "Cancel", style: .blue)
    private let helpButton = PillButton(title: "Get Help", style: .blue)
    private let statusLabel = NSTextField(labelWithString: "")
    private var stepViews: [NSImageView] = []
    private var stepLabels: [NSTextField] = []
    private var connecting = false
    private var cancelled = false
    private var aolSafety: [SafetyItem] = []
    private var macSafety: [SafetyItem] = []
    var touchIDOn = true
    var soundsOn = true

    private let steps = [
        ("network", "Step 1: Connecting"),
        ("lock.shield.fill", "Step 2: Checking password"),
        ("person.crop.circle.badge.checkmark", "Step 3: Signing on"),
    ]

    init(screenNames: [String], selected: String, location: String) {
        self.screenNames = screenNames.isEmpty ? [selected] : screenNames
        super.init(frame: NSRect(x: 0, y: 0, width: 590, height: 400))

        namePopup.font = Theme.ui(12)
        locationPopup.font = Theme.ui(12)
        rebuildNames(selecting: selected)
        locationPopup.addItems(withTitles: Self.locations)
        locationPopup.selectItem(withTitle: location)
        namePopup.target = self
        namePopup.action = #selector(nameChosen)

        optionsButton.action = { [weak self] in self?.showOptions() }
        signOnButton.action = { [weak self] in self?.submit() }
        cancelButton.action = { [weak self] in self?.cancel() }
        helpButton.action = { [weak self] in self?.onHelp?() }
        cancelButton.isHidden = true

        statusLabel.font = Theme.ui(12, bold: true)
        statusLabel.textColor = Theme.rgb(16, 50, 130)
        statusLabel.alignment = .center
        statusLabel.isHidden = true

        for (symbol, text) in steps {
            let image = NSImageView(image: Icons.symbol(symbol, size: 30, colors: [Theme.rgb(170, 186, 210)]) ?? NSImage())
            image.imageScaling = .scaleNone
            image.isHidden = true
            stepViews.append(image)
            let label = NSTextField(labelWithString: text)
            label.font = Theme.ui(11)
            label.alignment = .center
            label.textColor = Theme.mutedText
            label.isHidden = true
            stepLabels.append(label)
        }
        ([namePopup, locationPopup, optionsButton, signOnButton, cancelButton, helpButton, statusLabel] + stepViews + stepLabels)
            .forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedName: String { namePopup.titleOfSelectedItem ?? screenNames.first ?? NSUserName() }

    private var panelRect: NSRect { NSRect(x: 26, y: 50, width: bounds.width - 52, height: bounds.height - 74) }
    private var safetyRect: NSRect {
        let p = panelRect
        return NSRect(x: p.minX + 8, y: p.maxY - 126, width: p.width - 16, height: 98)
    }

    override func layout() {
        super.layout()
        let p = panelRect
        helpButton.frame = NSRect(x: bounds.width - 90, y: 12, width: 64, height: 26)
        namePopup.frame = NSRect(x: p.midX + 40, y: p.minY + 22, width: p.maxX - p.midX - 62, height: 26)
        locationPopup.frame = NSRect(x: p.midX + 40, y: p.minY + 112, width: p.maxX - p.midX - 62, height: 26)
        signOnButton.frame = NSRect(x: p.maxX - 132, y: p.minY + 150, width: 110, height: 28)
        optionsButton.frame = NSRect(x: signOnButton.frame.minX - 128, y: p.minY + 152, width: 116, height: 24)
        cancelButton.frame = NSRect(x: p.midX - 50, y: safetyRect.maxY - 34, width: 100, height: 26)

        let s = safetyRect
        statusLabel.frame = NSRect(x: s.minX, y: s.minY + 2, width: s.width, height: 18)
        let slot = s.width / CGFloat(steps.count)
        for i in steps.indices {
            stepViews[i].frame = NSRect(x: s.minX + slot * CGFloat(i), y: s.minY + 18, width: slot, height: 36)
            stepLabels[i].frame = NSRect(x: s.minX + slot * CGFloat(i), y: s.minY + 54, width: slot, height: 16)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(rect: bounds).addClip()
        Theme.gradient([Theme.rgb(236, 244, 252), Theme.rgb(196, 220, 244)], in: bounds)
        drawSwoosh(in: bounds, alpha: 0.6)

        let p = panelRect
        let panel = NSBezierPath(roundedRect: p, xRadius: 10, yRadius: 10)
        Theme.gradient([Theme.rgb(250, 252, 255), Theme.rgb(226, 238, 250)], in: panel)
        NSGraphicsContext.saveGraphicsState()
        panel.addClip()
        drawSwoosh(in: p, alpha: 0.9)
        NSGraphicsContext.restoreGraphicsState()
        Theme.rgb(132, 168, 210).setStroke()
        panel.lineWidth = 1.2
        panel.stroke()

        drawWordmark(in: NSRect(x: p.minX + 18, y: p.minY + 40, width: p.width / 2 - 90, height: 110))

        drawText("Screen Name:", font: Theme.ui(12, bold: true), color: Theme.text,
                 in: NSRect(x: p.midX - 70, y: p.minY + 26, width: 104, height: 18), align: .right)
        drawText("Location:", font: Theme.ui(12, bold: true), color: Theme.text,
                 in: NSRect(x: p.midX - 70, y: p.minY + 116, width: 104, height: 18), align: .right)

        if !connecting { drawSafety(in: safetyRect) }

        let keyword = NSMutableAttributedString(string: "Go to AOL-OS Keyword: ", attributes: [.font: Theme.ui(11), .foregroundColor: Theme.text])
        keyword.append(NSAttributedString(string: "Safety", attributes: [
            .font: Theme.ui(11), .foregroundColor: Theme.rgb(20, 60, 200), .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
        keyword.append(NSAttributedString(string: " to learn more about AOL-OS Safety, Security & Privacy",
                                          attributes: [.font: Theme.ui(11), .foregroundColor: Theme.text]))
        let size = keyword.size()
        keyword.draw(at: NSPoint(x: p.midX - size.width / 2, y: p.maxY - 22))
    }

    private func drawSwoosh(in rect: NSRect, alpha: CGFloat) {
        NSColor.white.withAlphaComponent(alpha).setStroke()
        for (i, lift) in [0.18, 0.26].enumerated() {
            let arc = NSBezierPath()
            arc.lineWidth = i == 0 ? 10 : 4
            arc.move(to: NSPoint(x: rect.minX - 20, y: rect.minY + rect.height * 0.55))
            arc.curve(to: NSPoint(x: rect.maxX + 20, y: rect.minY + rect.height * CGFloat(lift)),
                      controlPoint1: NSPoint(x: rect.minX + rect.width * 0.3, y: rect.minY - 10),
                      controlPoint2: NSPoint(x: rect.minX + rect.width * 0.6, y: rect.minY + rect.height * 0.5))
            arc.stroke()
        }
    }

    private func drawWordmark(in rect: NSRect) {
        let script = NSFont(name: "SnellRoundhand-Black", size: 36) ?? NSFont(name: "Georgia-BoldItalic", size: 32) ?? .boldSystemFont(ofSize: 32)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white
        shadow.shadowOffset = NSSize(width: 1, height: -1)
        let mark = NSAttributedString(string: "AOL-OS", attributes: [
            .font: script, .foregroundColor: Theme.rgb(40, 90, 160), .shadow: shadow,
        ])
        mark.draw(at: NSPoint(x: rect.minX, y: rect.minY + 6))

        let x = rect.minX + 12
        let nine = NSAttributedString(string: "9.0", attributes: [
            .font: NSFont(name: "Arial-BoldItalicMT", size: 32) ?? .boldSystemFont(ofSize: 32),
            .foregroundColor: Theme.rgb(236, 176, 30),
            .strokeColor: Theme.rgb(150, 100, 10), .strokeWidth: -2.5,
        ])
        nine.draw(at: NSPoint(x: x, y: rect.minY + 62))
        let band = NSRect(x: x + 50, y: rect.minY + 76, width: 112, height: 20)
        Theme.gradient([Theme.rgb(110, 150, 210), Theme.rgb(40, 80, 150)], in: NSBezierPath(roundedRect: band, xRadius: 10, yRadius: 10))
        drawText("OPTIMIZED", font: NSFont(name: "Arial-BoldItalicMT", size: 12) ?? .boldSystemFont(ofSize: 12),
                 color: .white, in: band.insetBy(dx: 8, dy: 0), align: .center)
        let se = NSRect(x: band.maxX + 4, y: band.minY + 1, width: 18, height: 18)
        Theme.rgb(236, 150, 30).setFill()
        NSBezierPath(ovalIn: se).fill()
        drawText("SE", font: Theme.ui(8, bold: true), color: .white, in: se, align: .center)
    }

    private func drawSafety(in rect: NSRect) {
        let box = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(0.75).setFill()
        box.fill()
        Theme.rgb(150, 180, 214).setStroke()
        box.stroke()
        let header = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 22)
        NSGraphicsContext.saveGraphicsState()
        box.addClip()
        Theme.gradient([Theme.rgb(248, 251, 255), Theme.rgb(222, 234, 248)], in: header)
        NSGraphicsContext.restoreGraphicsState()
        Theme.rgb(150, 180, 214).setFill()
        NSRect(x: rect.minX, y: header.maxY, width: rect.width, height: 1).fill()
        NSRect(x: rect.midX, y: rect.minY, width: 1, height: rect.height).fill()

        for (i, (title, items)) in [("Safety on AOL-OS", aolSafety), ("Safety on My Mac", macSafety)].enumerated() {
            let colX = rect.minX + CGFloat(i) * rect.width / 2
            if let shield = Icons.symbol("shield.lefthalf.filled", size: 11, colors: [Theme.mutedText]) {
                shield.draw(in: NSRect(x: colX + 8, y: 5, width: 12, height: 13).offsetBy(dx: 0, dy: rect.minY),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            drawText(title, font: Theme.ui(11, bold: true), color: Theme.text,
                     in: NSRect(x: colX + 24, y: rect.minY, width: rect.width / 2 - 30, height: 22))
            for (row, item) in items.prefix(4).enumerated() {
                let y = header.maxY + 4 + CGFloat(row) * 17
                drawText(item.label, font: Theme.ui(10), color: Theme.text,
                         in: NSRect(x: colX + 24, y: y, width: rect.width / 2 - 120, height: 15))
                let (text, color) = Self.badge(item.state)
                drawText(text, font: Theme.ui(10, bold: true), color: color,
                         in: NSRect(x: colX + rect.width / 2 - 96, y: y, width: 90, height: 15))
            }
        }
    }

    private static func badge(_ state: SafetyItem.State) -> (String, NSColor) {
        switch state {
        case .on: return ("ON", Theme.rgb(30, 150, 30))
        case .off: return ("Not Running", Theme.rgb(210, 20, 20))
        case .notDetected: return ("Not Detected", Theme.rgb(210, 20, 20))
        case .unknown: return ("--", Theme.mutedText)
        }
    }

    func setSafety(aol: [SafetyItem], mac: [SafetyItem]) {
        aolSafety = aol
        macSafety = mac
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(signOnButton)
    }

    private func rebuildNames(selecting name: String) {
        namePopup.removeAllItems()
        namePopup.addItems(withTitles: screenNames)
        namePopup.menu?.addItem(.separator())
        namePopup.addItem(withTitle: "New Screen Name...")
        namePopup.selectItem(withTitle: name)
    }

    @objc private func nameChosen() {
        guard namePopup.titleOfSelectedItem == "New Screen Name..." else { return }
        if let name = Prompt.text(title: "New Screen Name", message: "Type the screen name to add.", confirm: "Add"),
           !screenNames.contains(name) {
            screenNames.append(name)
            onScreenNamesChanged?(screenNames)
            rebuildNames(selecting: name)
        } else {
            rebuildNames(selecting: screenNames.first ?? "")
        }
    }

    private func showOptions() {
        let menu = NSMenu()
        let touch = ActionItem("Require Touch ID to Sign On") { [weak self] in
            self?.touchIDOn.toggle()
            self?.onToggleTouchID?()
        }
        touch.state = touchIDOn ? .on : .off
        menu.addItem(touch)
        let sounds = ActionItem("Play Sounds") { [weak self] in
            self?.soundsOn.toggle()
            self?.onToggleSounds?()
        }
        sounds.state = soundsOn ? .on : .off
        menu.addItem(sounds)
        if screenNames.count > 1 {
            menu.addItem(.separator())
            menu.addItem(ActionItem("Remove \"\(selectedName)\"") { [weak self] in
                guard let self else { return }
                self.screenNames.removeAll { $0 == self.selectedName }
                self.onScreenNamesChanged?(self.screenNames)
                self.rebuildNames(selecting: self.screenNames.first ?? "")
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: optionsButton.bounds.height), in: optionsButton)
    }

    private func submit() {
        guard !connecting else { return }
        onSignOn?(selectedName, locationPopup.titleOfSelectedItem ?? Self.locations[0])
    }

    private func cancel() {
        cancelled = true
        setConnecting(false)
        onCancel?()
    }

    func showError(_ message: String) {
        setConnecting(false)
        let alert = NSAlert()
        alert.messageText = "Sign On"
        alert.informativeText = message
        alert.runModal()
    }

    func setBusy(_ busy: Bool) {
        signOnButton.isEnabled = !busy
        optionsButton.isEnabled = !busy
        namePopup.isEnabled = !busy
        locationPopup.isEnabled = !busy
    }

    private func setConnecting(_ on: Bool) {
        connecting = on
        setBusy(on)
        cancelButton.isHidden = !on
        statusLabel.isHidden = !on
        (stepViews + stepLabels).forEach { $0.isHidden = !on }
        if on {
            for (i, view) in stepViews.enumerated() {
                view.image = Icons.symbol(steps[i].0, size: 30, colors: [Theme.rgb(170, 186, 210)])
            }
        }
        needsDisplay = true
    }

    func runConnectingSequence(dialUp: Bool, completion: @escaping () -> Void) {
        cancelled = false
        setConnecting(true)
        advance(step: 0, delay: dialUp ? 2.2 : 0.8, dialUp: dialUp, completion: completion)
    }

    private func advance(step: Int, delay: Double, dialUp: Bool, completion: @escaping () -> Void) {
        guard !cancelled else { return }
        guard step < steps.count else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.cancelled else { return }
                completion()
            }
            return
        }
        stepViews[step].image = Icons.symbol(steps[step].0, size: 30, colors: [Theme.rgb(20, 80, 180)])
        stepLabels[step].textColor = Theme.text
        var text = steps[step].1
        if step == 0 { text += dialUp ? " using Dial-Up (56K)" : " using TCP/IP" }
        statusLabel.stringValue = text + "..."
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.advance(step: step + 1, delay: delay, dialUp: dialUp, completion: completion)
        }
    }
}
