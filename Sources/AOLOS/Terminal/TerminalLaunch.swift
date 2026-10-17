import Foundation

/// What a terminal window runs, kept pure so it can be tested and saved with the window layout.
struct TerminalLaunch: Equatable {
    enum Kind: String, Codable {
        /// Claude Code, then the user's shell once it exits.
        case claude
        /// Just the user's login shell.
        case shell
    }

    var kind: Kind
    var directory: String
    /// Picks up the folder's last Claude Code conversation. Used when a window comes back at sign on.
    var resume = false

    static let installHint = "Claude Code is not installed. Get it at https://claude.com/claude-code"

    var title: String {
        let base = kind == .claude ? "Claude Code" : "Terminal"
        return "\(base) - \(Self.displayName(directory))"
    }

    /// The executable and arguments. A login, interactive shell loads the user's PATH even when
    /// AOL-OS was started from Finder, which only gets the minimal launchd PATH.
    func command(shell: String) -> (executable: String, args: [String]) {
        switch kind {
        case .shell:
            return (shell, ["-l"])
        case .claude:
            // --continue fails when the folder has no conversation yet, so fall back to a fresh one.
            let run = resume ? "claude --continue || claude" : "claude"
            let script = "if command -v claude >/dev/null 2>&1; then \(run); else echo '\(Self.installHint)'; fi; exec \"$SHELL\" -l"
            return (shell, ["-l", "-i", "-c", script])
        }
    }

    /// The child's environment: ours, minus anything that would make Claude Code think it is nested
    /// inside another Claude Code session, plus a terminal that supports color.
    static func environment(from base: [String: String], shell: String) -> [String] {
        var env = base.filter { key, _ in
            !(key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key == "TERM_PROGRAM"
              || key == "TERM_PROGRAM_VERSION" || key == "TERM_SESSION_ID" || key == "ITERM_SESSION_ID")
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "AOL-OS"
        env["SHELL"] = shell
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// The user's login shell, or zsh.
    static func userShell(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let shell = env["SHELL"], !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) { return shell }
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        return "/bin/zsh"
    }

    static func displayName(_ directory: String) -> String {
        let home = NSHomeDirectory()
        if directory == home || directory.isEmpty { return "Home" }
        return (directory as NSString).lastPathComponent
    }

    /// `~/Projects/x` style path for menus.
    static func abbreviated(_ directory: String) -> String {
        (directory as NSString).abbreviatingWithTildeInPath
    }
}

/// Folders Claude Code was opened in, newest first.
enum RecentFolders {
    static let key = "ClaudeCodeRecentFolders"
    static let limit = 8

    static func adding(_ folder: String, to list: [String]) -> [String] {
        Array(([folder] + list.filter { $0 != folder }).prefix(limit))
    }

    static func load(_ defaults: UserDefaults = .standard) -> [String] {
        (defaults.stringArray(forKey: key) ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func remember(_ folder: String, _ defaults: UserDefaults = .standard) {
        defaults.set(adding(folder, to: load(defaults)), forKey: key)
    }
}
