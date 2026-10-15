import AppKit

/// The AOL Radio window: stations on the left, the selected station and Now Playing in the middle, Up Next on the right.
final class RadioView: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    var onAddPreset: ((RadioStation) -> Void)?
    var onRemovePreset: ((RadioStation) -> Void)?
    var onOpenLink: ((URL) -> Void)?
    var onConnect: (() -> Void)?
    var onError: ((Error) -> Void)?

    let spotify: SpotifyService
    private var expanded: Set<SpotifyService.Category> = [.presets, .playlists]
    private var rows: [StationRowView.Row] = []
    private var selectedStation: RadioStation?
    private var tick: Timer?
    private var volumeWork: DispatchWorkItem?

    private let stationsPanel = RadioPanel(title: "Stations by Category")
    private let stationPanel = RadioPanel(title: "Station")
    private let nowPanel = RadioPanel(title: "Now Playing")
    private let nextPanel = RadioPanel(title: "Up Next")
    private let search = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()

    private let stopButton = TransportButton(kind: .stop)
    private let playButton = TransportButton(kind: .play)
    private let prevButton = ChromeButton(symbol: "backward.end.fill")
    private let nextButton = ChromeButton(symbol: "forward.end.fill")
    private let volume = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let setupButton = ChromeButton(title: "Radio Setup")
    private let helpButton = ChromeButton(title: "Help")
    private let presetButton = ChromeButton(title: "Add to My Presets")
    private let likeButton = ChromeButton(title: "Save Song", symbol: "heart")

    private let stationTitle = NSTextField(labelWithString: "")
    private let stationDetail = NSTextField(wrappingLabelWithString: "")
    private let stationLink = LinkLabel()

    private let art = NSImageView()
    private let artist = LinkLabel()
    private let song = LinkLabel()
    private let album = LinkLabel()
    private let elapsed = NSTextField(labelWithString: "")
    private let progress = ProgressStrip()
    private let getIt = LinkLabel()
    private let upNext = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let connectPanel = FlippedView()
    private let connectLabel = NSTextField(wrappingLabelWithString: "")

    init(spotify: SpotifyService) {
        self.spotify = spotify
        super.init(frame: .zero)

        search.placeholderString = "Find a song, album or playlist"
        search.font = Theme.ui(11)
        search.target = self
        search.action = #selector(runSearch)
        search.sendsWholeSearchString = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("station"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.selectionHighlightStyle = .none
        table.backgroundColor = .white
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        stationsPanel.content.addSubview(search)
        stationsPanel.content.addSubview(scroll)

        stationTitle.font = Theme.ui(14, bold: true)
        stationTitle.textColor = Theme.rgb(20, 40, 110)
        stationTitle.lineBreakMode = .byTruncatingTail
        stationDetail.font = Theme.ui(11)
        stationDetail.textColor = Theme.text
        stationDetail.maximumNumberOfLines = 4
        presetButton.action = { [weak self] in self?.togglePreset() }
        stationPanel.headerAccessory = presetButton
        [stationTitle, stationDetail, stationLink].forEach(stationPanel.content.addSubview)

        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.borderColor = Theme.chromeShade.cgColor
        art.layer?.borderWidth = 1
        elapsed.font = Theme.ui(11, bold: true)
        song.bold = true
        likeButton.action = { [weak self] in self?.likeCurrent() }
        nowPanel.headerAccessory = likeButton
        [art, artist, song, album, elapsed, progress, getIt].forEach(nowPanel.content.addSubview)

        upNext.font = Theme.ui(11)
        upNext.textColor = Theme.text
        nextPanel.content.addSubview(upNext)

        stopButton.action = { [weak self] in self?.perform { try await $0.stop() } }
        playButton.action = { [weak self] in self?.playPressed() }
        prevButton.action = { [weak self] in self?.perform { try await $0.previous() } }
        nextButton.action = { [weak self] in self?.perform { try await $0.next() } }
        volume.target = self
        volume.action = #selector(volumeChanged)
        volume.controlSize = .small
        setupButton.action = { [weak self] in self?.showSetupMenu() }
        helpButton.action = { [weak self] in self?.showHelp() }

        footer.font = Theme.ui(10)
        footer.textColor = Theme.mutedText
        footer.alignment = .center

        connectLabel.font = Theme.ui(13)
        connectLabel.alignment = .center
        let connect = ChromeButton(title: "Connect Spotify", symbol: "dot.radiowaves.left.and.right", prominent: true) { [weak self] in
            self?.onConnect?()
        }
        connect.identifier = NSUserInterfaceItemIdentifier("connect")
        [connectLabel, connect].forEach(connectPanel.addSubview)

        [stationsPanel, stationPanel, nowPanel, nextPanel, stopButton, playButton, prevButton, nextButton,
         volume, setupButton, helpButton, footer, connectPanel].forEach(addSubview)

        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    func stop() {
        tick?.invalidate()
        tick = nil
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12, header: CGFloat = 64, footerH: CGFloat = 20
        let bodyTop = header + 6
        let bodyBottom = bounds.height - footerH - 4
        let leftW: CGFloat = 230, rightW: CGFloat = min(220, max(160, bounds.width * 0.22))
        let midX = pad + leftW + pad
        let midW = bounds.width - midX - rightW - pad * 2
        let transportH: CGFloat = 74

        helpButton.frame = NSRect(x: bounds.width - 70, y: 20, width: 58, height: 24)
        stationsPanel.frame = NSRect(x: pad, y: bodyTop, width: leftW, height: bodyBottom - bodyTop - transportH)
        stationsPanel.layout()
        let c = stationsPanel.content.bounds
        search.frame = NSRect(x: 4, y: 4, width: c.width - 8, height: 22)
        scroll.frame = NSRect(x: 0, y: 30, width: c.width, height: max(0, c.height - 30))
        table.tableColumns.first?.width = c.width - 4

        let ty = stationsPanel.frame.maxY + 10
        stopButton.frame = NSRect(x: pad + 2, y: ty, width: 30, height: 30)
        playButton.frame = NSRect(x: pad + 38, y: ty, width: 30, height: 30)
        prevButton.frame = NSRect(x: pad + 76, y: ty + 4, width: 26, height: 22)
        nextButton.frame = NSRect(x: pad + 104, y: ty + 4, width: 26, height: 22)
        volume.frame = NSRect(x: pad + 136, y: ty + 6, width: leftW - 136, height: 18)
        setupButton.frame = NSRect(x: pad + (leftW - 110) / 2, y: ty + 38, width: 110, height: 24)

        let stationH: CGFloat = 132
        stationPanel.frame = NSRect(x: midX, y: bodyTop, width: midW, height: stationH)
        stationPanel.layout()
        let s = stationPanel.content.bounds
        stationTitle.frame = NSRect(x: 8, y: 6, width: s.width - 16, height: 20)
        stationDetail.frame = NSRect(x: 8, y: 28, width: s.width - 16, height: 56)
        stationLink.frame = NSRect(x: 8, y: s.height - 22, width: s.width - 16, height: 16)

        nowPanel.frame = NSRect(x: midX, y: stationPanel.frame.maxY + 10, width: midW, height: bodyBottom - stationPanel.frame.maxY - 10)
        nowPanel.layout()
        let n = nowPanel.content.bounds
        let artSize = min(110, n.height - 40)
        art.frame = NSRect(x: 8, y: 8, width: artSize, height: artSize)
        let lx = art.frame.maxX + 12, lw = n.width - lx - 8
        artist.frame = NSRect(x: lx, y: 10, width: lw, height: 16)
        song.frame = NSRect(x: lx, y: 30, width: lw, height: 16)
        album.frame = NSRect(x: lx, y: 50, width: lw, height: 16)
        elapsed.frame = NSRect(x: lx, y: 76, width: lw, height: 16)
        progress.frame = NSRect(x: lx, y: 96, width: lw, height: 8)
        getIt.frame = NSRect(x: 8, y: n.height - 22, width: n.width - 16, height: 16)

        nextPanel.frame = NSRect(x: bounds.width - rightW - pad, y: bodyTop, width: rightW, height: bodyBottom - bodyTop)
        nextPanel.layout()
        upNext.frame = nextPanel.content.bounds.insetBy(dx: 8, dy: 8)

        footer.frame = NSRect(x: pad, y: bounds.height - footerH, width: bounds.width - pad * 2, height: 16)

        connectPanel.frame = NSRect(x: 0, y: header, width: bounds.width, height: bounds.height - header)
        connectLabel.frame = NSRect(x: (bounds.width - 420) / 2, y: 70, width: 420, height: 60)
        if let connect = connectPanel.subviews.first(where: { $0.identifier?.rawValue == "connect" }) as? ChromeButton {
            let w = connect.preferredWidth + 12
            connect.frame = NSRect(x: (bounds.width - w) / 2, y: 140, width: w, height: 30)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gradient([Theme.rgb(255, 255, 255), Theme.rgb(226, 234, 246)], in: bounds)
        let header = NSRect(x: 0, y: 0, width: bounds.width, height: 64)
        Theme.gradient([Theme.rgb(255, 255, 255), Theme.rgb(236, 242, 252)], in: header)
        Theme.rgb(180, 196, 224).setFill()
        NSRect(x: 0, y: 63, width: bounds.width, height: 1).fill()

        let title = NSAttributedString(string: "AOL Radio", attributes: [
            .font: NSFont(name: "Helvetica-Bold", size: 30) ?? .boldSystemFont(ofSize: 30),
            .foregroundColor: Theme.rgb(16, 76, 160),
        ])
        title.draw(at: NSPoint(x: 14, y: 14))
        let x = 14 + title.size().width + 12
        NSAttributedString(string: "Featuring", attributes: [
            .font: Theme.ui(10), .foregroundColor: Theme.mutedText,
        ]).draw(at: NSPoint(x: x, y: 22))
        drawWaves(at: NSPoint(x: x + 66, y: 30))
        NSAttributedString(string: "Spotify", attributes: [
            .font: NSFont(name: "Helvetica-Bold", size: 22) ?? .boldSystemFont(ofSize: 22),
            .foregroundColor: Theme.rgb(30, 160, 80),
        ]).draw(at: NSPoint(x: x + 88, y: 16))
    }

    private func drawWaves(at c: NSPoint) {
        Theme.rgb(200, 30, 40).setStroke()
        for i in 0..<3 {
            let r = CGFloat(5 + i * 5)
            for side in [-1.0, 1.0] {
                let arc = NSBezierPath()
                arc.lineWidth = 2.2
                let start: CGFloat = side < 0 ? 140 : -40
                arc.appendArc(withCenter: c, radius: r, startAngle: start, endAngle: start + 80)
                arc.stroke()
            }
        }
        Theme.rgb(200, 30, 40).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)).fill()
    }

    func reload() {
        let connected = spotify.auth.isConnected
        connectPanel.isHidden = connected
        [stationsPanel, stationPanel, nowPanel, nextPanel, stopButton, playButton, prevButton, nextButton, volume, setupButton]
            .forEach { $0.isHidden = !connected }
        connectLabel.stringValue = spotify.auth.clientID == nil
            ? "This build has no Spotify app ID. Add one in Settings, then connect. See docs/spotify.md."
            : "Sign in with Spotify to tune in. Playback control needs Spotify Premium."

        rows = []
        for category in SpotifyService.Category.allCases {
            let items = spotify.stations[category] ?? []
            if category == .search && items.isEmpty { continue }
            let open = expanded.contains(category)
            rows.append(.category(category, expanded: open, count: items.count))
            if open { rows += items.map { .station($0) } }
        }
        table.reloadData()

        let player = spotify.player
        let current = selectedStation ?? stationForContext(player?.contextURI)
        showStation(current)

        let track = player?.track
        artist.text = "Artist: " + (track?.artistLine ?? "")
        artist.action = linkAction(track?.artistURL)
        song.text = "Song: " + (track?.name ?? "Nothing playing")
        song.action = linkAction(track?.trackURL)
        album.text = "Album: " + (track?.album ?? "")
        album.action = linkAction(track?.albumURL)
        getIt.text = track == nil ? "" : "Get It: Open in Spotify"
        getIt.action = track?.trackURL.map { url -> () -> Void in { NSWorkspace.shared.open(url) } }
        likeButton.isEnabled = track != nil
        ImageLoader.load(track?.imageURL, into: art)
        playButton.kind = player?.isPlaying == true ? .pause : .play
        if let v = player?.device?.volume, volumeWork == nil { volume.integerValue = v }

        upNext.stringValue = spotify.queue.isEmpty ? "Nothing queued."
            : spotify.queue.prefix(8).enumerated().map { "\($0.offset + 1). \($0.element.name)\n    \($0.element.artistLine)" }
                .joined(separator: "\n")
        let who = spotify.auth.userName.map { "Signed in as \($0). " } ?? ""
        footer.stringValue = who + spotify.status
        updateClock()
        needsLayout = true
    }

    private func linkAction(_ url: URL?) -> (() -> Void)? {
        guard let url else { return nil }
        return { [weak self] in self?.onOpenLink?(url) }
    }

    private func stationForContext(_ uri: String?) -> RadioStation? {
        guard let uri else { return nil }
        return spotify.stations.values.joined().first { $0.contextURI == uri }
    }

    private func showStation(_ station: RadioStation?) {
        stationTitle.stringValue = station?.title ?? "Tune in to a station"
        stationDetail.stringValue = station?.subtitle ?? "Pick a playlist, album or song from Stations by Category."
        if let web = station?.webURL.flatMap(URL.init(string:)) {
            stationLink.text = "Open this station in Spotify"
            stationLink.action = { [weak self] in self?.onOpenLink?(web) }
        } else {
            stationLink.text = ""
            stationLink.action = nil
        }
        let isPreset = station.map { s in (spotify.stations[.presets] ?? []).contains(s) } ?? false
        presetButton.title = isPreset ? "Remove Preset" : "Add to My Presets"
        presetButton.isEnabled = station?.contextURI != nil
    }

    private func updateClock() {
        guard let player = spotify.player, let track = player.track else {
            elapsed.stringValue = "Time Elapsed: 0:00"
            progress.fraction = 0
            return
        }
        let now = player.progress()
        elapsed.stringValue = "Time Elapsed: \(PlayerState.clock(now)) of \(PlayerState.clock(track.durationMs))"
        progress.fraction = track.durationMs > 0 ? CGFloat(now) / CGFloat(track.durationMs) : 0
    }

    private func perform(_ work: @escaping @MainActor (SpotifyService) async throws -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do { try await work(self.spotify) } catch { self.onError?(error) }
        }
    }

    private func playPressed() {
        if spotify.player == nil, let station = selectedStation {
            perform { try await $0.play(station) }
        } else {
            perform { try await $0.togglePlay() }
        }
    }

    @objc private func rowClicked() {
        let i = table.clickedRow
        guard i >= 0, i < rows.count else { return }
        switch rows[i] {
        case .category(let category, _, _):
            if expanded.contains(category) { expanded.remove(category) } else { expanded.insert(category) }
            reload()
        case .station(let station):
            selectedStation = station
            showStation(station)
            table.reloadData()
            perform { try await $0.play(station) }
        }
    }

    @objc private func runSearch() {
        let text = search.stringValue
        expanded.insert(.search)
        Task { [weak self] in await self?.spotify.search(text) }
    }

    @objc private func volumeChanged() {
        volumeWork?.cancel()
        let value = volume.integerValue
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.volumeWork = nil
                self?.perform { try await $0.setVolume(value) }
            }
        }
        volumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func togglePreset() {
        guard let station = selectedStation ?? stationForContext(spotify.player?.contextURI) else { return }
        if (spotify.stations[.presets] ?? []).contains(station) {
            onRemovePreset?(station)
        } else {
            onAddPreset?(station)
        }
        showStation(station)
    }

    private func likeCurrent() {
        guard let track = spotify.player?.track else { return }
        perform { service in
            try await service.like(track)
            SoundManager.shared.play(.fileDone)
        }
    }

    private func showSetupMenu() {
        Task { [weak self] in
            guard let self else { return }
            try? await self.spotify.loadDevices()
            let menu = NSMenu()
            menu.addItem(withTitle: "Play On", action: nil, keyEquivalent: "").isEnabled = false
            if self.spotify.devices.isEmpty {
                menu.addItem(withTitle: "No Spotify devices found", action: nil, keyEquivalent: "").isEnabled = false
            }
            for device in self.spotify.devices {
                let item = ActionItem("\(device.name) (\(device.type))") { [weak self] in
                    self?.perform { try await $0.transfer(to: device) }
                }
                item.state = device.isActive ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            if self.spotify.spotifyAppURL != nil {
                menu.addItem(ActionItem("Start Spotify on This Mac") { [weak self] in
                    Task { await self?.spotify.launchSpotifyApp() }
                })
            }
            menu.addItem(ActionItem("Refresh Stations") { [weak self] in
                Task { await self?.spotify.loadLibrary() }
            })
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.setupButton.bounds.height), in: self.setupButton)
        }
    }

    private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "AOL Radio"
        alert.informativeText = "Click a station to tune in. Playlists and albums can be saved as presets. "
            + "Music plays through Spotify on this Mac or any device picked in Radio Setup. "
            + "Controlling playback needs Spotify Premium."
        alert.runModal()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("stationRow"), owner: nil) as? StationRowView
            ?? {
                let v = StationRowView()
                v.identifier = NSUserInterfaceItemIdentifier("stationRow")
                return v
            }()
        view.row = rows[row]
        if case .station(let station) = rows[row] {
            view.isCurrent = station == (selectedStation ?? stationForContext(spotify.player?.contextURI))
        } else {
            view.isCurrent = false
        }
        return view
    }
}
