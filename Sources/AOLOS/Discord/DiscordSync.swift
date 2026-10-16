import AppKit

/// Rechecks open conversations on a timer. Live events can be dropped while the Discord window reconnects.
@MainActor
enum DiscordSync {
    static let interval: TimeInterval = 20
    private static var timer: Timer?

    static func start(_ session: Session) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak session] _ in
            MainActor.assumeIsolated { session?.syncConversations() }
        }
    }
}
