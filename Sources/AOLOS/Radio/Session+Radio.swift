import AppKit

extension Session {
    func openRadio() {
        guard signedOn else { return }
        if let w = radioWindow, w.superview != nil {
            desktop.activate(w)
            return
        }
        spotify.setPresets(config.radioPresets)
        let view = RadioView(spotify: spotify)
        view.onOpenLink = { [weak self] url in self?.openBrowser(url) }
        view.onConnect = { [weak self] in self?.connectSpotify() }
        view.onError = { [weak self] error in self?.showRadioError(error) }
        view.onAddPreset = { [weak self] station in
            self?.updateConfig { $0.radioPresets.append(station) }
            self?.spotify.setPresets(self?.config.radioPresets ?? [])
        }
        view.onRemovePreset = { [weak self] station in
            self?.updateConfig { $0.radioPresets.removeAll { $0 == station } }
            self?.spotify.setPresets(self?.config.radioPresets ?? [])
        }

        let window = MDIWindow(title: "AOL Radio", icon: Icons.symbol("dot.radiowaves.left.and.right", colors: [.white]), content: view)
        window.minSize = NSSize(width: 760, height: 470)
        window.onClose = { [weak self] in
            self?.radioView?.stop()
            self?.radioView = nil
            self?.radioWindow = nil
        }
        radioWindow = window
        radioView = view
        desktop.add(window, size: NSSize(width: 860, height: 520))

        if spotify.auth.isConnected {
            spotify.startPolling()
            Task { [weak self] in await self?.spotify.loadLibrary() }
        }
    }

    /// Spotify polling runs for the whole signed-on session so the toolbar readout stays current.
    func setUpNowPlaying() {
        spotify.onChange = { [weak self] in
            self?.radioView?.reload()
            self?.refreshNowPlaying()
        }
        let widget = shell.toolbar.nowPlaying
        widget.onOpen = { [weak self] in self?.openRadio() }
        widget.onTogglePlay = { [weak self] in self?.radioCommand { try await $0.togglePlay() } }
        widget.onNext = { [weak self] in self?.radioCommand { try await $0.next() } }
    }

    func refreshNowPlaying() {
        let state: NowPlayingWidget.State
        if !signedOn {
            state = .signedOff
        } else if !spotify.auth.isConnected {
            state = .disconnected
        } else if let player = spotify.player, let track = player.track {
            state = .playing(track, isPlaying: player.isPlaying)
        } else {
            state = .idle
        }
        shell.toolbar.nowPlaying.show(state, player: spotify.player)
    }

    private func radioCommand(_ work: @escaping @MainActor (SpotifyService) async throws -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do { try await work(self.spotify) } catch { self.showRadioError(error) }
        }
    }

    func connectSpotify() {
        guard spotify.auth.clientID != nil else {
            openSettings()
            let alert = NSAlert()
            alert.messageText = "AOL Radio needs a Spotify app ID"
            alert.informativeText = "This build has no built-in Spotify app. Paste a client ID into Settings, then connect. The steps are in docs/spotify.md."
            alert.runModal()
            return
        }
        shell.statusBar.status = "Waiting for Spotify sign in in your browser..."
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.spotify.auth.connect()
                self.shell.statusBar.status = "Spotify connected"
                self.radioView?.reload()
                self.settingsView?.refreshSpotifyStatus()
                self.spotify.startPolling()
                await self.spotify.loadLibrary()
            } catch {
                self.shell.statusBar.status = "Spotify sign in failed"
                self.showRadioError(error)
            }
        }
    }

    func disconnectSpotify() {
        spotify.stopPolling()
        spotify.auth.disconnect()
        radioView?.reload()
        refreshNowPlaying()
        settingsView?.refreshSpotifyStatus()
    }

    func showRadioError(_ error: Error) {
        shell.statusBar.status = error.localizedDescription
        let alert = NSAlert()
        alert.messageText = "AOL Radio"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
