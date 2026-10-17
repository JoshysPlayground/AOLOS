import AppKit

/// AOL Radio now playing readout inside the toolbar group. Clicking the body opens AOL Radio.
final class NowPlayingWidget: PressableView {
    enum State: Equatable {
        case signedOff
        case disconnected
        case idle
        case playing(SpotifyTrack, isPlaying: Bool)
    }

    var onOpen: (() -> Void)? { didSet { action = onOpen } }
    var onTogglePlay: (() -> Void)? { didSet { playButton.action = onTogglePlay } }
    var onNext: (() -> Void)? { didSet { nextButton.action = onNext } }

    private(set) var state: State = .signedOff
    private var player: PlayerState?
    private let art = NSImageView()
    private let playButton = TransportButton(kind: .play)
    private let nextButton = ChromeButton(symbol: "forward.end.fill")
    private let progress = ProgressStrip()
    private var tick: Timer?
    private static let artSize: CGFloat = 36

    override init(frame: NSRect) {
        super.init(frame: frame)
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 3
        art.layer?.masksToBounds = true
        playButton.toolTip = "Play or pause"
        nextButton.toolTip = "Next song"
        toolTip = "AOL Radio"
        [art, playButton, nextButton, progress].forEach(addSubview)
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProgress() }
        }
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: State, player: PlayerState?) {
        self.player = player
        if state != self.state {
            self.state = state
            apply()
        }
        updateProgress()
    }

    override var isEnabled: Bool { didSet { if !isEnabled { show(.signedOff, player: nil) } } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === art || hit === progress ? self : hit
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private var hasTrack: Bool {
        if case .playing = state { return true }
        return false
    }

    private func apply() {
        if case .playing(let track, let isPlaying) = state {
            ImageLoader.load(track.imageURL, into: art)
            playButton.kind = isPlaying ? .pause : .play
            toolTip = "\(track.name) by \(track.artistLine)"
        } else {
            art.image = nil
            art.toolTip = nil
            toolTip = "AOL Radio"
        }
        art.isHidden = track?.imageURL == nil
        [playButton, nextButton, progress].forEach { $0.isHidden = !hasTrack }
        needsLayout = true
        needsDisplay = true
    }

    private var track: SpotifyTrack? {
        if case .playing(let track, _) = state { return track }
        return nil
    }

    private func updateProgress() {
        guard let player, let track = player.track, track.durationMs > 0, hasTrack else {
            progress.fraction = 0
            return
        }
        progress.fraction = CGFloat(player.progress()) / CGFloat(track.durationMs)
    }

    private var artRect: NSRect {
        NSRect(x: 5, y: (bounds.height - Self.artSize) / 2, width: Self.artSize, height: Self.artSize)
    }

    private var textX: CGFloat { artRect.maxX + 7 }
    private var textMaxX: CGFloat { hasTrack ? bounds.width - 52 : bounds.width - 8 }

    override func layout() {
        super.layout()
        art.frame = artRect
        let b: CGFloat = 22
        playButton.frame = NSRect(x: bounds.width - 2 * b - 6, y: (bounds.height - b) / 2 - 2, width: b, height: b)
        nextButton.frame = NSRect(x: bounds.width - b - 4, y: (bounds.height - 18) / 2 - 2, width: b, height: 18)
        progress.frame = NSRect(x: textX, y: bounds.height - 7, width: max(0, textMaxX - textX), height: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.45
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        var colors = [Theme.rgb(255, 255, 255), Theme.rgb(226, 236, 250)]
        if isEnabled, isPressed { colors.reverse() } else if isEnabled, isHovered { colors = [Theme.rgb(255, 252, 236), Theme.rgb(250, 232, 170)] }
        Theme.gradient(colors, in: panel)
        Theme.toolbarLine.setStroke()
        panel.lineWidth = 1
        panel.stroke()

        if art.isHidden || art.image == nil {
            let tile = NSBezierPath(roundedRect: artRect, xRadius: 3, yRadius: 3)
            Theme.gradient([Theme.rgb(92, 140, 214), Theme.rgb(38, 86, 170)].map { $0.withAlphaComponent(alpha) }, in: tile)
            Icons.symbol("dot.radiowaves.left.and.right", size: 18, colors: [.white])?
                .draw(in: artRect.insetBy(dx: 8, dy: 9), from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        }

        let (label, title, detail): (String, String, String) = switch state {
        case .signedOff: ("AOL RADIO", "AOL Radio", "Sign on to listen")
        case .disconnected: ("AOL RADIO", "AOL Radio", "Connect Spotify to tune in")
        case .idle: ("AOL RADIO", "Nothing playing", "Click to pick a station")
        case .playing(let track, let isPlaying): (isPlaying ? "NOW PLAYING" : "PAUSED", track.name, track.artistLine)
        }
        let width = max(0, textMaxX - textX)
        let labelColor = hasTrack && playButton.kind == .pause ? Theme.rgb(30, 150, 50) : Theme.aolBlue
        drawText(label, font: Theme.caption(8.5), color: labelColor.withAlphaComponent(alpha),
                 in: NSRect(x: textX, y: 2, width: width, height: 11))
        drawText(title, font: Theme.ui(11, bold: true), color: Theme.rgb(20, 40, 110).withAlphaComponent(alpha),
                 in: NSRect(x: textX, y: 12, width: width, height: 15))
        drawText(detail, font: Theme.ui(10), color: Theme.mutedText.withAlphaComponent(alpha),
                 in: NSRect(x: textX, y: hasTrack ? 25 : 26, width: width, height: 13))
    }
}
