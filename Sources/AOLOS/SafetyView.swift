import AppKit

/// The Safety window opened from the toolbar. It shows the same checks as the Sign On window.
final class SafetyView: FlippedView {
    var onRefresh: (() -> Void)?
    private var aol: [SafetyItem] = []
    private var mac: [SafetyItem] = []
    private let refresh = PillButton(title: "Check Again", style: .blue)

    override init(frame: NSRect) {
        super.init(frame: frame)
        refresh.action = { [weak self] in self?.onRefresh?() }
        addSubview(refresh)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(aol: [SafetyItem], mac: [SafetyItem]) {
        self.aol = aol
        self.mac = mac
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        refresh.frame = NSRect(x: bounds.width - 128, y: bounds.height - 40, width: 112, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient([Theme.rgb(236, 244, 252), Theme.rgb(204, 224, 246)], in: bounds)
        if let shield = AppPaths.brandingImage("Toolbar/safety-active.png") ?? Icons.symbol("shield.lefthalf.filled", size: 30, colors: [Theme.aolBlue]) {
            shield.draw(in: NSRect(x: 16, y: 14, width: 40, height: 40), from: .zero, operation: .sourceOver,
                        fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        drawText("Safety & Security", font: Theme.ui(16, bold: true), color: Theme.rgb(16, 50, 130),
                 in: NSRect(x: 66, y: 14, width: bounds.width - 80, height: 22))
        drawText("Live status of AOL-OS protections and this Mac's security settings.", font: Theme.ui(11),
                 color: Theme.mutedText, in: NSRect(x: 66, y: 36, width: bounds.width - 80, height: 16))
        SafetyTable.draw(in: NSRect(x: 16, y: 66, width: bounds.width - 32, height: 98), aol: aol, mac: mac)
    }
}

extension Session {
    func aolSafetyItems() -> [SafetyItem] {
        [
            SafetyItem(label: "Touch ID Sign On", state: config.requireTouchID ? .on : .off),
            SafetyItem(label: "Mail Image Blocking", state: .on),
            SafetyItem(label: "Keychain Password Saving", state: .on),
            SafetyItem(label: "Gmail Connection", state: mail.isConnected ? .on : .unknown),
        ]
    }

    func openSafety() {
        guard signedOn else { return }
        let view = SafetyView()
        let window = MDIWindow(title: "Safety", icon: Icons.symbol("shield.lefthalf.filled", colors: [.white]), content: view)
        window.minSize = NSSize(width: 520, height: 240)
        desktop.add(window, size: NSSize(width: 600, height: 250), centered: true)
        let check = { [weak self, weak view] in
            guard let self else { return }
            view?.set(aol: self.aolSafetyItems(), mac: [])
            Task { [weak view] in view?.set(aol: self.aolSafetyItems(), mac: await MacSafety.check()) }
        }
        view.onRefresh = check
        check()
    }
}
