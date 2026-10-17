import XCTest
@testable import AOLOS

final class TerminalLaunchTests: XCTestCase {
    func testClaudeCommandRunsClaudeThenShell() {
        let launch = TerminalLaunch(kind: .claude, directory: "/tmp")
        let cmd = launch.command(shell: "/bin/zsh")
        XCTAssertEqual(cmd.executable, "/bin/zsh")
        XCTAssertEqual(Array(cmd.args.prefix(3)), ["-l", "-i", "-c"])
        let script = cmd.args[3]
        XCTAssertTrue(script.contains("then claude;"))
        XCTAssertFalse(script.contains("--continue"))
        XCTAssertTrue(script.hasSuffix("exec \"$SHELL\" -l"))
    }

    func testResumeFallsBackToFreshConversation() {
        let script = TerminalLaunch(kind: .claude, directory: "/tmp", resume: true).command(shell: "/bin/zsh").args[3]
        XCTAssertTrue(script.contains("claude --continue || claude"))
    }

    func testShellIsLoginShell() {
        let cmd = TerminalLaunch(kind: .shell, directory: "/tmp").command(shell: "/bin/bash")
        XCTAssertEqual(cmd.executable, "/bin/bash")
        XCTAssertEqual(cmd.args, ["-l"])
    }

    func testEnvironmentDropsNestedClaudeMarkers() {
        let env = TerminalLaunch.environment(from: [
            "PATH": "/usr/bin", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
            "TERM": "dumb", "TERM_PROGRAM": "iTerm.app", "LANG": "de_DE.UTF-8",
        ], shell: "/bin/zsh")
        XCTAssertTrue(env.contains("PATH=/usr/bin"))
        XCTAssertTrue(env.contains("TERM=xterm-256color"))
        XCTAssertTrue(env.contains("COLORTERM=truecolor"))
        XCTAssertTrue(env.contains("TERM_PROGRAM=AOL-OS"))
        XCTAssertTrue(env.contains("SHELL=/bin/zsh"))
        XCTAssertTrue(env.contains("LANG=de_DE.UTF-8"))
        XCTAssertFalse(env.contains { $0.hasPrefix("CLAUDECODE=") || $0.hasPrefix("CLAUDE_CODE_") })
    }

    func testTitles() {
        XCTAssertEqual(TerminalLaunch(kind: .claude, directory: "/Users/x/Projects/AOL-OS").title, "Claude Code - AOL-OS")
        XCTAssertEqual(TerminalLaunch(kind: .shell, directory: NSHomeDirectory()).title, "Terminal - Home")
    }

    func testRecentFoldersNewestFirstWithoutDuplicates() {
        var list: [String] = []
        list = RecentFolders.adding("/a", to: list)
        list = RecentFolders.adding("/b", to: list)
        list = RecentFolders.adding("/a", to: list)
        XCTAssertEqual(list, ["/a", "/b"])
        for i in 0..<20 { list = RecentFolders.adding("/f\(i)", to: list) }
        XCTAssertEqual(list.count, RecentFolders.limit)
        XCTAssertEqual(list.first, "/f19")
    }

    func testSavedTerminalWindowRoundTrips() throws {
        let saved = SavedWindow(kind: .terminal, id: "claude", url: "/tmp", frame: CGRect(x: 1, y: 2, width: 300, height: 200))
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(SavedWindow.self, from: data), saved)
    }
}
