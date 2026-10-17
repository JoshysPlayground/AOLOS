import AppKit
import SwiftTerm

/// SwiftTerm's local process view, with the bell and links handed back to AOL-OS.
final class AOLTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?
    var onOpenLink: ((URL) -> Void)?

    override func bell(source: Terminal) {
        onBell?()
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
           let onOpenLink {
            onOpenLink(url)
        } else {
            super.requestOpenLink(source: source, link: link, params: params)
        }
    }
}

/// A window's worth of terminal: runs Claude Code (or a shell) in a pseudo terminal.
final class TerminalPane: NSView, LocalProcessTerminalViewDelegate {
    static let background = Theme.rgb(16, 20, 34)
    static let foreground = Theme.rgb(222, 226, 236)
    static let inset: CGFloat = 6

    let launch: TerminalLaunch
    let terminal = AOLTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    /// The title the running program asked for, if any.
    var onTitle: ((String) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onBell: (() -> Void)? {
        get { terminal.onBell }
        set { terminal.onBell = newValue }
    }
    var onOpenLink: ((URL) -> Void)? {
        get { terminal.onOpenLink }
        set { terminal.onOpenLink = newValue }
    }
    private(set) var running = false
    /// The shell's current folder when it reports one (OSC 7), otherwise where it started.
    private(set) var currentDirectory: String

    init(launch: TerminalLaunch) {
        self.launch = launch
        self.currentDirectory = launch.directory
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor
        terminal.processDelegate = self
        terminal.font = NSFont(name: "SFMono-Regular", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = Self.background
        terminal.nativeForegroundColor = Self.foreground
        terminal.caretColor = Theme.rgb(255, 196, 0)
        terminal.optionAsMetaKey = true
        addSubview(terminal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        terminal.frame = bounds.insetBy(dx: Self.inset, dy: Self.inset)
    }

    func start() {
        guard !running else { return }
        let shell = TerminalLaunch.userShell()
        let command = launch.command(shell: shell)
        let env = TerminalLaunch.environment(from: ProcessInfo.processInfo.environment, shell: shell)
        let directory = FileManager.default.fileExists(atPath: launch.directory) ? launch.directory : NSHomeDirectory()
        running = true
        terminal.startProcess(executable: command.executable, args: command.args, environment: env,
                              execName: nil, currentDirectory: directory)
    }

    /// Ends the program and everything it started. Called when the window closes.
    /// SwiftTerm's terminate() only sends SIGTERM to the shell, which an interactive shell ignores,
    /// so Claude Code kept running after its window closed. Hang up the way closing a terminal does.
    func stop() {
        guard running else { return }
        running = false
        let pid = terminal.process.shellPid
        let fd = terminal.process.childfd
        let foreground = fd >= 0 ? tcgetpgrp(fd) : -1
        if foreground > 0 { killpg(foreground, SIGHUP) }
        if pid > 0 { kill(pid, SIGHUP) }
        terminal.terminate()
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if foreground > 0, foreground != pid, killpg(foreground, 0) == 0 { killpg(foreground, SIGKILL) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            // SwiftTerm stops watching the child once terminated, so reap it here.
            waitpid(pid, nil, 0)
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated { onTitle?(title) }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        MainActor.assumeIsolated { currentDirectory = url.path }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            let wasRunning = running
            running = false
            guard wasRunning else { return }
            if exitCode != 0 {
                let code = exitCode.map(String.init) ?? "unknown"
                terminal.feed(text: "\r\n\u{1b}[2m[Process exited with code \(code). Close the window when you are done.]\u{1b}[0m\r\n")
            }
            onExit?(exitCode)
        }
    }
}
