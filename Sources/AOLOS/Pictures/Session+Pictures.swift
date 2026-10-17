import AppKit
import Photos

extension Session {
    func openPictures() {
        guard signedOn else { return }
        if let w = picturesWindow, w.superview != nil {
            desktop.activate(w)
            return
        }
        let view = PicturesView(library: photos)
        view.onView = { [weak self] assets, index in self?.openPhoto(assets, index) }
        view.onSendInMail = { [weak self] assets in self?.sendPicturesInMail(assets) }
        view.onError = { [weak self] error in self?.showPicturesError(error) }
        view.onOpenLink = { url in NSWorkspace.shared.open(url) }
        photos.onChange = { [weak self] in self?.picturesView?.reload() }

        let window = MDIWindow(title: "AOL Pictures", icon: Icons.symbol("photo.on.rectangle", colors: [.white]), content: view)
        window.minSize = NSSize(width: 620, height: 420)
        window.onClose = { [weak self] in
            self?.picturesWindow = nil
            self?.picturesView = nil
        }
        picturesWindow = window
        picturesView = view
        desktop.add(window, size: NSSize(width: min(desktop.bounds.width * 0.85, 1080),
                                         height: min(desktop.bounds.height * 0.9, 720)))
    }

    func openPhoto(_ assets: PHFetchResult<PHAsset>, _ index: Int) {
        let view = PhotoViewerView(library: photos, assets: assets, index: index)
        let window = MDIWindow(title: "Picture", icon: Icons.symbol("photo", colors: [.white]), content: view)
        window.minSize = NSSize(width: 480, height: 360)
        window.focusView = view
        window.onClose = { [weak view] in view?.stop() }
        view.onTitle = { [weak window] title in window?.title = title }
        view.onSendInMail = { [weak self] asset in self?.sendPicturesInMail([asset]) }
        view.onError = { [weak self] error in self?.showPicturesError(error) }
        desktop.add(window, size: NSSize(width: min(desktop.bounds.width * 0.75, 1000),
                                         height: min(desktop.bounds.height * 0.85, 760)))
    }

    /// Opens Write Mail with the pictures attached once their files are ready.
    func sendPicturesInMail(_ assets: [PHAsset]) {
        guard mail.isConnected else {
            openMailbox()
            return
        }
        shell.statusBar.status = "Preparing \(assets.count) picture\(assets.count == 1 ? "" : "s") for mail..."
        Task { [weak self] in
            guard let self else { return }
            do {
                let files = try await self.photos.mailAttachments(assets)
                self.shell.statusBar.status = ""
                let subject = files.count == 1 ? "A picture for you" : "Some pictures for you"
                self.openCompose(subject: subject, attachments: files)
            } catch {
                self.shell.statusBar.status = ""
                self.showPicturesError(error)
            }
        }
    }

    func showPicturesError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "AOL Pictures"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
