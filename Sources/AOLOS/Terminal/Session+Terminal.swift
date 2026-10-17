import AppKit

extension Session {
    /// Opens Claude Code in `directory`, or the most recent folder, or Home.
    @discardableResult
    func openClaudeCode(in directory: String? = nil, resume: Bool = false) -> MDIWindow? {
        let folder = directory ?? RecentFolders.load().first ?? NSHomeDirectory()
        RecentFolders.remember(folder)
        return openTerminalWindow(TerminalLaunch(kind: .claude, directory: folder, resume: resume))
    }

    @discardableResult
    func openTerminal(in directory: String? = nil) -> MDIWindow? {
        openTerminalWindow(TerminalLaunch(kind: .shell, directory: directory ?? NSHomeDirectory()))
    }

    /// Asks for a folder, then opens Claude Code there.
    func chooseClaudeCodeFolder() {
        guard signedOn else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose the folder Claude Code should work in."
        if let recent = RecentFolders.load().first { panel.directoryURL = URL(fileURLWithPath: recent) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openClaudeCode(in: url.path)
    }

    /// Toolbar and menu row: Claude Code in recent folders, a folder picker, and a plain terminal.
    func claudeCodeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionItem("New Claude Code Window") { [weak self] in self?.openClaudeCode() })
        menu.addItem(ActionItem("Claude Code in Folder...") { [weak self] in self?.chooseClaudeCodeFolder() })
        let recent = RecentFolders.load()
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent Folders", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for folder in recent {
                let item = ActionItem(TerminalLaunch.abbreviated(folder)) { [weak self] in self?.openClaudeCode(in: folder) }
                item.image = Icons.symbol("folder.fill", size: 13, colors: [Theme.aolBlue])
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("New Terminal Window") { [weak self] in self?.openTerminal() })
        return menu
    }

    /// Hangs up every Claude Code and terminal window, for quitting.
    func stopTerminals() {
        for case let pane as TerminalPane in desktop.windows.map(\.content) { pane.stop() }
    }

    @discardableResult
    func openTerminalWindow(_ launch: TerminalLaunch) -> MDIWindow? {
        guard signedOn else { NSSound.beep(); return nil }
        let pane = TerminalPane(launch: launch)
        let symbol = launch.kind == .claude ? "sparkle" : "terminal.fill"
        let window = MDIWindow(title: launch.title, icon: Icons.symbol(symbol, colors: [.white]), content: pane)
        window.minSize = NSSize(width: 420, height: 260)
        window.focusView = pane.terminal
        window.onClose = { [weak pane] in pane?.stop() }
        pane.onTitle = { [weak window] title in
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            window?.title = t.isEmpty ? launch.title : "\(t) - \(TerminalLaunch.displayName(launch.directory))"
        }
        pane.onExit = { [weak self, weak window] code in
            // A clean exit (typing `exit` in the shell) closes the window, like Terminal does.
            guard code == 0, let self, let window, window.superview != nil else { return }
            self.desktop.close(window, force: true)
        }
        pane.onBell = { [weak window] in
            // Claude Code rings the bell when it finishes or needs an answer.
            guard let window else { return }
            if !window.isActive || !NSApp.isActive {
                window.attention = true
                SoundManager.shared.play(.notify)
            }
        }
        pane.onOpenLink = { [weak self] url in self?.openBrowser(url) }
        desktop.add(window, size: NSSize(width: min(desktop.bounds.width * 0.7, 960),
                                         height: min(desktop.bounds.height * 0.8, 640)))
        pane.start()
        return window
    }
}
