import AppKit

final class KioskWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var session: Session!
    private var windowTracker: AppWindowTracker?
    private let windowed = CommandLine.arguments.contains("--windowed")
    /// Links macOS hands over before the session exists.
    private var launchURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        if let brand = Icons.brand { NSApp.applicationIconImage = brand }
        let shell = ShellView(framed: !windowed)

        if windowed {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "AOL-OS"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = true
            }
            window.minSize = NSSize(width: 900, height: 600)
            window.center()
            windowTracker = AppWindowTracker(window: window)
            windowTracker?.restoreFrame()
        } else {
            let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            window = KioskWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrame(frame, display: true)
            NotificationCenter.default.addObserver(
                self, selector: #selector(screenChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }

        window.isReleasedWhenClosed = false
        window.contentView = shell
        session = Session(shell: shell)
        NSApp.mainMenu = MainMenu.build(session: session)
        if windowed { wireWindowControls(shell.titleBar) }

        window.makeKeyAndOrderFront(nil)
        windowTracker?.restoreState()
        NSApp.activate()
        applyKioskOptions()
        session.start()
        session.openExternal(launchURLs)
        launchURLs = []
    }

    /// Links and web pages opened from other apps when AOL-OS is the default browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let session else { launchURLs += urls; return }
        session.openExternal(urls)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        applyKioskOptions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowTracker?.update()
        session?.saveWindowLayout()
        session?.stopTerminals()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func applyKioskOptions() {
        guard !windowed else { return }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }

    /// Luna buttons drive the real window, since the macOS buttons are hidden.
    private func wireWindowControls(_ bar: AppTitleBar) {
        bar.maxButton.isHidden = false
        bar.minButton.action = { [weak self] in self?.window.miniaturize(nil) }
        bar.maxButton.action = { [weak self] in self?.window.zoom(nil) }
        bar.onDoubleClick = { [weak self] in self?.window.zoom(nil) }
        bar.needsLayout = true
    }

    @objc private func screenChanged() {
        if let frame = window.screen?.frame ?? NSScreen.main?.frame {
            window.setFrame(frame, display: true)
        }
    }
}
