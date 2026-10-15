import AppKit

final class SignOnView: FlippedView {
    var onSignOn: ((String) -> Void)?

    private let nameField = NSTextField()
    private let signOnButton = ChromeButton(title: "Sign On", prominent: true)
    private let statusLabel = NSTextField(labelWithString: "")
    private let passwordNote = NSTextField(labelWithString: "")
    private var stepViews: [NSImageView] = []
    private let steps = [
        ("network", "Step 1: Connecting"),
        ("lock.shield.fill", "Step 2: Checking password"),
        ("person.crop.circle.badge.checkmark", "Step 3: Signing on"),
    ]

    init(screenName: String, usesTouchID: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 380))

        nameField.stringValue = screenName
        nameField.font = Theme.ui(13)
        nameField.placeholderString = "Screen Name"
        nameField.target = self
        nameField.action = #selector(submit)
        passwordNote.stringValue = usesTouchID ? "Password: Touch ID or Mac password" : "Password: not required"
        passwordNote.font = Theme.ui(11)
        passwordNote.textColor = Theme.mutedText
        statusLabel.font = Theme.ui(12, bold: true)
        statusLabel.textColor = Theme.aolBlue
        statusLabel.alignment = .center
        signOnButton.action = { [weak self] in self?.submit() }

        for (symbol, _) in steps {
            let v = NSImageView(image: Icons.symbol(symbol, size: 26, colors: [Theme.chromeShade]) ?? NSImage())
            v.imageScaling = .scaleNone
            stepViews.append(v)
            addSubview(v)
        }
        [nameField, passwordNote, signOnButton, statusLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        nameField.frame = NSRect(x: 40, y: 168, width: w - 80, height: 24)
        passwordNote.frame = NSRect(x: 40, y: 200, width: w - 80, height: 18)
        let stepWidth: CGFloat = 60
        let total = stepWidth * CGFloat(stepViews.count)
        for (i, v) in stepViews.enumerated() {
            v.frame = NSRect(x: (w - total) / 2 + CGFloat(i) * stepWidth, y: 230, width: stepWidth, height: 40)
        }
        statusLabel.frame = NSRect(x: 20, y: 274, width: w - 40, height: 20)
        signOnButton.frame = NSRect(x: (w - 120) / 2, y: bounds.height - 52, width: 120, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill()
        bounds.fill()
        let banner = NSRect(x: 0, y: 0, width: bounds.width, height: 120)
        Theme.gradient([Theme.rgb(255, 255, 255), Theme.rgb(214, 228, 248)], in: banner)
        drawText("AOL-OS", font: NSFont(name: "Helvetica-Bold", size: 48) ?? .boldSystemFont(ofSize: 48),
                 color: Theme.aolBlue, in: NSRect(x: 0, y: 18, width: bounds.width, height: 64), align: .center)
        drawText("9.0 Optimized SE", font: Theme.ui(12), color: Theme.mutedText,
                 in: NSRect(x: 0, y: 82, width: bounds.width, height: 20), align: .center)
        drawText("Select Screen Name:", font: Theme.ui(11, bold: true), color: Theme.text,
                 in: NSRect(x: 40, y: 146, width: 200, height: 18))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(nameField)
    }

    @objc private func submit() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, signOnButton.isEnabled else { NSSound.beep(); return }
        onSignOn?(name)
    }

    func showError(_ message: String) {
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = message
        setBusy(false)
    }

    func setBusy(_ busy: Bool) {
        signOnButton.isEnabled = !busy
        nameField.isEnabled = !busy
    }

    func runConnectingSequence(completion: @escaping () -> Void) {
        setBusy(true)
        statusLabel.textColor = Theme.aolBlue
        advance(step: 0, completion: completion)
    }

    private func advance(step: Int, completion: @escaping () -> Void) {
        guard step < steps.count else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: completion)
            return
        }
        stepViews[step].image = Icons.symbol(steps[step].0, size: 26, colors: [Theme.aolBlue])
        statusLabel.stringValue = steps[step].1 + "..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.advance(step: step + 1, completion: completion)
        }
    }
}
