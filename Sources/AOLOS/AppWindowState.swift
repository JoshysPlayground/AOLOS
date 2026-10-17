import AppKit

/// Where the app window was in windowed mode. `frame` is the un-zoomed frame, so zooming back after a relaunch
/// returns to it.
struct AppWindowState: Codable, Equatable {
    var frame: CGRect
    var zoomed = false
    var fullScreen = false

    /// A frame is used again only while most of its title area is on a connected screen.
    static func isUsable(_ frame: CGRect, screens: [CGRect], minSize: CGSize) -> Bool {
        guard frame.width >= minSize.width, frame.height >= minSize.height else { return false }
        let top = CGRect(x: frame.minX, y: frame.maxY - 40, width: frame.width, height: 40)
        let visible = screens.reduce(CGFloat(0)) { sum, screen in
            let overlap = top.intersection(screen)
            return sum + (overlap.isNull ? 0 : overlap.width)
        }
        return visible >= min(200, frame.width / 2)
    }
}

/// Saves the windowed-mode app window's frame, zoom and full screen state to user defaults and puts them back at launch.
@MainActor
final class AppWindowTracker {
    static let defaultsKey = "AppWindowState"
    private let window: NSWindow
    private let defaults: UserDefaults
    private var state: AppWindowState
    private var observers: [NSObjectProtocol] = []

    init(window: NSWindow, defaults: UserDefaults = .standard) {
        self.window = window
        self.defaults = defaults
        state = AppWindowState(frame: window.frame)
    }

    static func load(from defaults: UserDefaults = .standard) -> AppWindowState? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(AppWindowState.self, from: data)
    }

    /// Call before the window is shown. Sets the saved frame.
    func restoreFrame() {
        window.collectionBehavior.insert(.fullScreenPrimary)
        guard let saved = Self.load(from: defaults),
              AppWindowState.isUsable(saved.frame, screens: NSScreen.screens.map(\.visibleFrame), minSize: window.minSize)
        else { return }
        state = saved
        window.setFrame(saved.frame, display: false)
    }

    /// Call after the window is shown. Zooms or enters full screen like last time, then starts tracking.
    func restoreState() {
        if state.fullScreen {
            window.toggleFullScreen(nil)
        } else if state.zoomed, !window.isZoomed {
            window.zoom(nil)
        }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                                          NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification]
        observers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
    }

    func update() {
        guard !window.isMiniaturized else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        state.fullScreen = fullScreen
        if !fullScreen {
            state.zoomed = window.isZoomed
            if !state.zoomed { state.frame = window.frame }
        }
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
