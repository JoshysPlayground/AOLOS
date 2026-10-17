import AppKit

extension Session {
    enum ReplyMode { case reply, replyAll, forward }

    func setUpMail() {
        RemoteContentBlocker.prepare()
        mail.onChange = { [weak self] in
            self?.updateReadIcon()
            self?.mailboxView?.reload()
            self?.updateWelcomeMail()
            self?.settingsView?.refreshGmailStatus()
        }
        mail.onNewMail = { [weak self] in
            SoundManager.shared.play(.gotMail)
            if let w = self?.mailboxWindow, !w.isActive { w.attention = true }
            self?.desktop.windowsChanged()
        }
    }

    /// The Read button shows the flag-up mailbox while unread mail is waiting.
    func updateReadIcon() {
        shell.toolbar.leftItems.first?.name = mail.unreadCount > 0 ? "read" : "read-closed"
    }

    func updateWelcomeMail() {
        guard let pane = welcomePane else { return }
        if !mail.isConnected {
            pane.setMailState("Connect Gmail in Settings to get mail here", hasMail: false)
        } else if !mail.hasLoaded {
            pane.setMailState(mail.isRunning ? "Checking mail..." : "Open your Mailbox to check mail", hasMail: false)
        } else if mail.unreadCount > 0 {
            pane.setMailState("You've Got Mail! (\(mail.unreadCount) new)", hasMail: true)
        } else {
            pane.setMailState("No new mail", hasMail: false)
        }
    }

    func openMailbox(minimized: Bool = false) {
        guard signedOn else { return }
        if mail.isConnected { mail.start() }
        if let w = mailboxWindow, w.superview != nil {
            if !minimized { desktop.activate(w) }
            return
        }
        let view = MailboxView(mail: mail)
        view.onOpen = { [weak self] summary in self?.openMessage(summary) }
        view.onAction = { [weak self] action, summaries in self?.mailboxAction(action, summaries) }
        view.onOpenLink = { [weak self] url in self?.openBrowser(url) }
        let window = MDIWindow(title: "Mailbox", icon: Icons.symbol("envelope.fill", colors: [.white]), content: view)
        window.minSize = NSSize(width: 640, height: 420)
        window.onClose = { [weak self] in
            self?.mailboxWindow = nil
            self?.mailboxView = nil
        }
        mailboxWindow = window
        mailboxView = view
        desktop.add(window, size: NSSize(width: min(desktop.bounds.width * 0.85, 1040),
                                         height: min(desktop.bounds.height * 0.9, 720)), minimized: minimized)
    }

    private func mailboxAction(_ action: MailboxView.Action, _ summaries: [MailSummary]) {
        let summary = summaries.first
        let account = mailboxView?.account
        switch action {
        case .read:
            summaries.prefix(5).forEach(openMessage)
        case .write:
            openCompose(from: account)
        case .reply, .forward:
            guard let summary else { return }
            let mode: ReplyMode = action == .reply ? .reply : .forward
            Task { [weak self] in
                guard let self else { return }
                do {
                    self.openReply(mode, to: try await self.mail.message(summary))
                } catch {
                    self.showMailError(error)
                }
            }
        case .markRead, .keepAsNew:
            let seen = action == .markRead
            Task { [weak self] in
                do { try await self?.mail.setSeen(summaries, seen) } catch { self?.showMailError(error) }
            }
        case .delete:
            Task { [weak self] in
                do { try await self?.mail.delete(summaries) } catch { self?.showMailError(error) }
            }
        case .reportSpam:
            Task { [weak self] in
                do { try await self?.mail.reportSpam(summaries) } catch { self?.showMailError(error) }
            }
        case .refresh:
            Task { [weak self] in
                do { try await self?.mail.refresh(account: account) } catch { self?.showMailError(error) }
            }
        case .connect:
            connectGmail()
        case .webGmail:
            openGmailWeb(account: account)
        }
    }

    /// Gmail on the web in the `google` profile. `authuser` picks the account when that profile is signed in to several.
    func openGmailWeb(account: String?) {
        guard let account, mail.accounts.count > 1 else {
            openService("mail", web: true)
            return
        }
        var c = URLComponents(string: "https://mail.google.com/mail/")!
        c.queryItems = [URLQueryItem(name: "authuser", value: account)]
        if let url = c.url { openBrowser(url, profile: config.service("mail")?.profile ?? "google") }
    }

    func openMessage(_ summary: MailSummary) {
        let view = MessageView()
        let window = MDIWindow(title: summary.subject, icon: Icons.symbol("envelope.open.fill", colors: [.white]), content: view)
        window.minSize = NSSize(width: 480, height: 320)
        desktop.add(window, size: NSSize(width: min(desktop.bounds.width * 0.7, 900), height: min(desktop.bounds.height * 0.85, 760)))
        let isSent = summary.folder != "INBOX"
        if mail.accounts.count > 1, !summary.account.isEmpty { window.title = "\(summary.subject) (\(summary.account))" }

        view.onOpenLink = { [weak self] url in self?.openBrowser(url) }
        view.onAction = { [weak self, weak view, weak window] action in
            guard let self, let message = view?.message else { return }
            switch action {
            case .reply: self.openReply(.reply, to: message)
            case .replyAll: self.openReply(.replyAll, to: message)
            case .forward: self.openReply(.forward, to: message)
            case .keepAsNew, .delete:
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        if action == .delete {
                            try await self.mail.delete([summary])
                        } else {
                            try await self.mail.setSeen([summary], false)
                        }
                        if let window { self.desktop.close(window) }
                    } catch {
                        self.showMailError(error)
                    }
                }
            }
        }

        Task { [weak self, weak view] in
            guard let self else { return }
            do {
                let message = try await self.mail.message(summary)
                view?.show(message, isSent: isSent)
            } catch {
                view?.showError(error.localizedDescription)
            }
        }
    }

    func openReply(_ mode: ReplyMode, to message: MailMessage) {
        let mine = Set(mail.emails.map { $0.lowercased() })
        let from = MailCenter.replyAccount(account: message.summary.account, to: message.to, cc: message.cc, accounts: mail.emails)
        let sender = message.replyTo ?? message.from
        var to = "", cc = "", subject = message.subject, body = ""

        switch mode {
        case .reply, .replyAll:
            if !subject.lowercased().hasPrefix("re:") { subject = "Re: " + subject }
            to = sender
            if mode == .replyAll {
                let senderEmail = MailAddress.email(sender).lowercased()
                let others = MailAddress.split(message.to) + MailAddress.split(message.cc)
                cc = others.filter {
                    let e = MailAddress.email($0).lowercased()
                    return !mine.contains(e) && e != senderEmail
                }.joined(separator: ", ")
            }
            let quoted = message.plainText.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            body = "\n\nOn \(message.date), \(MailAddress.name(message.from)) wrote:\n\(quoted)"
        case .forward:
            if !subject.lowercased().hasPrefix("fwd:") { subject = "Fwd: " + subject }
            body = "\n\n----- Forwarded Message -----\nFrom: \(message.from)\nDate: \(message.date)\n"
                + "Subject: \(message.subject)\nTo: \(message.to)\n\n\(message.plainText)"
        }

        let references = mode == .forward ? nil : [message.references, message.messageID].compactMap { $0 }.joined(separator: " ")
        openCompose(to: to, cc: cc, subject: subject, body: body, from: from,
                    inReplyTo: mode == .forward ? nil : message.messageID, references: references)
    }

    func openCompose(to: String = "", cc: String = "", subject: String = "", body: String = "", from: String? = nil,
                     inReplyTo: String? = nil, references: String? = nil, attachments: [MailAttachment] = []) {
        guard signedOn else { return }
        let accounts = mail.accounts.filter(\.auth.isConnected).map(\.email)
        guard let primary = accounts.first else {
            openMailbox()
            return
        }
        let chosen = from.flatMap { f in accounts.first { $0.caseInsensitiveCompare(f) == .orderedSame } } ?? primary
        let view = ComposeView(to: to, cc: cc, subject: subject, body: body, accounts: accounts, from: chosen)
        attachments.forEach(view.addAttachment)
        let window = MDIWindow(title: subject.isEmpty ? "Write Mail" : subject,
                               icon: Icons.symbol("square.and.pencil", colors: [.white]), content: view)
        window.minSize = NSSize(width: 620, height: 440)
        window.focusView = view.preferredFirstResponder
        desktop.add(window, size: NSSize(width: min(desktop.bounds.width * 0.7, 860), height: min(desktop.bounds.height * 0.85, 640)))

        view.onAddressBook = { [weak self, weak view] anchor in
            guard let self, let view else { return }
            self.showAddressBook(for: view, from: anchor)
        }
        view.onSend = { [weak self, weak view, weak window] in
            guard let self, let view else { return }
            let from = view.fromAccount
            let outgoing = view.makeOutgoing(from: from, inReplyTo: inReplyTo,
                                             references: references?.isEmpty == true ? nil : references)
            guard !outgoing.recipients.isEmpty else {
                view.showStatus("Add someone to send to.")
                NSSound.beep()
                return
            }
            view.setBusy(true)
            Task { [weak self] in
                do {
                    try await self?.mail.send(outgoing, from: from)
                    SoundManager.shared.play(.mailSent)
                    if let window { self?.desktop.close(window) }
                } catch {
                    view.setBusy(false)
                    view.showStatus(error.localizedDescription)
                }
            }
        }
    }

    /// Recent correspondents stand in for the AOL Address Book.
    private func showAddressBook(for view: ComposeView, from anchor: NSView) {
        var seen = Set<String>()
        let mine = Set(mail.emails.map { $0.lowercased() })
        var people: [String] = []
        for address in mail.inbox.map(\.from) + mail.sent.flatMap({ MailAddress.split($0.to) }) {
            let email = MailAddress.email(address).lowercased()
            guard !email.isEmpty, !mine.contains(email), seen.insert(email).inserted else { continue }
            people.append(address)
            if people.count == 30 { break }
        }
        let menu = NSMenu()
        if people.isEmpty {
            let empty = NSMenuItem(title: "No recent addresses", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for person in people.sorted(by: { MailAddress.name($0).localizedCaseInsensitiveCompare(MailAddress.name($1)) == .orderedAscending }) {
            let title = "\(MailAddress.name(person)) <\(MailAddress.email(person))>"
            menu.addItem(ActionItem(title) { [weak view] in view?.insertAddress(person) })
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }

    /// Adds a Gmail account, or signs one in again when `hint` names it. Google shows its account chooser either way.
    func connectGmail(hint: String? = nil) {
        guard mail.hasClient else {
            openSettings()
            let alert = NSAlert()
            alert.messageText = "Gmail needs a Google OAuth client"
            alert.informativeText = "This build has no built-in client. Paste a client ID and secret into Settings, then click Connect Gmail. The steps are in docs/gmail.md."
            alert.runModal()
            return
        }
        shell.statusBar.status = "Waiting for Google sign in in your browser..."
        Task { [weak self] in
            guard let self else { return }
            do {
                let email = try await GoogleAccounts.signIn(hint: hint)
                self.shell.statusBar.status = "Gmail connected as \(email)"
                self.mail.reloadAccounts()
                self.mail.restart(email)
                self.mail.start()
                self.mailboxView?.reload()
                self.settingsView?.refreshGmailStatus()
                self.updateWelcomeMail()
            } catch {
                self.shell.statusBar.status = "Gmail sign in failed"
                self.showMailError(error)
            }
        }
    }

    func removeGmail(_ email: String) {
        let alert = NSAlert()
        alert.messageText = "Remove \(email)?"
        alert.informativeText = "AOL-OS signs out of this account and stops checking its mail. Your mail stays in Gmail."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        GoogleAccounts.remove(email)
        mail.reloadAccounts()
        mailboxView?.reload()
        settingsView?.refreshGmailStatus()
        updateWelcomeMail()
    }

    func makePrimaryGmail(_ email: String) {
        GoogleAccounts.makePrimary(email)
        mail.reloadAccounts()
        mailboxView?.reload()
        settingsView?.refreshGmailStatus()
        updateWelcomeMail()
    }

    func showMailError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Mail"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
