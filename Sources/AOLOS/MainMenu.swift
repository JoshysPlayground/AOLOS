import AppKit

/// The macOS menu bar is hidden in kiosk mode, but it still supplies key equivalents and the Edit actions web views need.
@MainActor
enum MainMenu {
    static func build(session: Session) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "AOL-OS")
        app.addItem(ActionItem("About AOL-OS") { showAbout() })
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide AOL-OS", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(ActionItem("Quit AOL-OS", key: "q") { session.quit() })
        add(app, to: main)

        let file = NSMenu(title: "File")
        file.addItem(ActionItem("New Browser Window", key: "n") { [weak session] in
            session?.openBrowser(URL(string: "https://www.google.com")!)
        })
        file.addItem(ActionItem("Keyword...", key: "k") { [weak session] in session?.promptKeyword() })
        file.addItem(ActionItem("Close Window", key: "w") { [weak session] in session?.closeActiveWindow() })
        file.addItem(.separator())
        file.addItem(ActionItem("Sign Off", key: "q", modifiers: [.command, .shift]) { [weak session] in session?.signOff() })
        add(file, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        add(edit, to: main)

        let view = NSMenu(title: "View")
        view.addItem(ActionItem("Reload", key: "r") { [weak session] in session?.reloadOrStop() })
        view.addItem(ActionItem("Back", key: "[") { [weak session] in session?.back() })
        view.addItem(ActionItem("Forward", key: "]") { [weak session] in session?.forward() })
        view.addItem(.separator())
        view.addItem(ActionItem("Zoom In", key: "=") { [weak session] in session?.zoom(by: 0.1) })
        view.addItem(ActionItem("Zoom Out", key: "-") { [weak session] in session?.zoom(by: -0.1) })
        view.addItem(ActionItem("Actual Size", key: "0") { [weak session] in session?.zoom(by: nil) })
        add(view, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(ActionItem("Minimize", key: "m") { [weak session] in
            if let s = session, let w = s.desktop.activeWindow { s.desktop.minimize(w) }
        })
        window.addItem(ActionItem("Next Window", key: "`") { [weak session] in session?.desktop.cycle() })
        window.addItem(ActionItem("Cascade") { [weak session] in session?.desktop.cascade() })
        window.addItem(ActionItem("Tile") { [weak session] in session?.desktop.tile() })
        add(window, to: main)

        return main
    }

    /// The in-window AOL menu row. Menus are rebuilt on every click so the Window list stays current.
    static func rowItems(session: Session) -> [MenuRowItem] {
        func item(_ title: String, _ build: @escaping (NSMenu) -> Void) -> MenuRowItem {
            MenuRowItem(title: title) {
                let menu = NSMenu(title: title)
                menu.autoenablesItems = false
                build(menu)
                return menu
            }
        }

        return [
            item("File") { [weak session] m in
                m.addItem(ActionItem("New Browser Window") { session?.openBrowser(URL(string: "https://www.google.com")!) })
                m.addItem(ActionItem("Open Keyword...") { session?.promptKeyword() })
                m.addItem(ActionItem("Close Window") { session?.closeActiveWindow() })
                m.addItem(.separator())
                m.addItem(ActionItem("Exit") { session?.quit() })
            },
            item("Edit") { m in
                m.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: ""))
                m.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""))
                m.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: ""))
                m.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: ""))
            },
            item("Mail") { [weak session] m in
                m.addItem(ActionItem("Read Mail") { session?.openService("mail") })
                m.addItem(ActionItem("Write Mail") { session?.openService("write") })
            },
            item("Community") { [weak session] m in
                m.addItem(ActionItem("Buddy List (Discord)") { session?.openBuddyList() })
                m.addItem(ActionItem("Chat (Discord)") { session?.openService("chat") })
                m.addItem(ActionItem("Instant Message (Slack)") { session?.openService("im") })
            },
            item("Services") { [weak session] m in
                m.addItem(ActionItem("AOL Radio") { session?.openRadio() })
                m.addItem(ActionItem("YouTube Music") { session?.openService("ytmusic") })
                m.addItem(ActionItem("Spotify Web Player") { session?.openService("spotify", web: true) })
                m.addItem(ActionItem("Finance") { session?.openService("finance") })
            },
            item("Settings") { [weak session] m in
                m.addItem(ActionItem("Preferences...") { session?.openSettings() })
                m.addItem(ActionItem("Open Sounds Folder") {
                    SoundManager.writeSoundsReadme()
                    NSWorkspace.shared.open(AppPaths.sounds)
                })
            },
            item("Window") { [weak session] m in
                guard let session else { return }
                m.addItem(ActionItem("Cascade") { session.desktop.cascade() })
                m.addItem(ActionItem("Tile") { session.desktop.tile() })
                m.addItem(ActionItem("Close All") { session.desktop.closeAll() })
                let windows = session.desktop.windows
                if !windows.isEmpty { m.addItem(.separator()) }
                for w in windows {
                    let entry = ActionItem(w.title) { [weak w] in if let w { session.desktop.activate(w) } }
                    entry.state = w.isActive ? .on : .off
                    m.addItem(entry)
                }
            },
            item("Keyword") { [weak session] m in
                m.addItem(ActionItem("Go to Keyword...") { session?.promptKeyword() })
            },
            item(session.signedOn ? "Sign Off" : "Sign On") { [weak session] m in
                if session?.signedOn == true {
                    m.addItem(ActionItem("Sign Off") { session?.signOff() })
                } else {
                    m.addItem(withTitle: "Use the Sign On window to sign on", action: nil, keyEquivalent: "").isEnabled = false
                }
                m.addItem(ActionItem("Exit AOL-OS") { session?.quit() })
            },
            item("Help") { m in
                m.addItem(ActionItem("About AOL-OS") { showAbout() })
            },
        ]
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }

    static func showAbout() {
        let alert = NSAlert()
        alert.messageText = "AOL Operating System"
        alert.informativeText = "A personal desktop shell for Gmail, Discord, Slack, music and banking."
        alert.runModal()
    }
}
