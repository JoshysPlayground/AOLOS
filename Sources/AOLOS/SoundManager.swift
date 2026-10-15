import AppKit

enum SoundEvent: String, CaseIterable {
    case welcome
    case goodbye
    case gotMail = "gotmail"
    case imReceive = "imrcv"
    case imSend = "imsend"
    case doorOpen = "dooropen"
    case doorClose = "doorclose"
    case fileDone = "filedone"
    case mailSent = "mailsent"
    case notify

    /// macOS system sound used until the user drops in their own file.
    var fallback: NSSound.Name? {
        switch self {
        case .welcome: return "Hero"
        case .goodbye: return "Submarine"
        case .gotMail: return "Glass"
        case .imReceive: return "Pop"
        case .imSend: return "Tink"
        case .doorOpen: return "Bottle"
        case .doorClose: return "Frog"
        case .fileDone: return "Purr"
        case .mailSent: return "Blow"
        case .notify: return "Ping"
        }
    }
}

@MainActor
final class SoundManager: NSObject, NSSoundDelegate {
    static let shared = SoundManager()
    static let extensions = ["wav", "mp3", "aif", "aiff", "m4a", "caf"]

    var enabled = true
    private var playing: [NSSound] = []
    private var lastPlayed: [SoundEvent: Date] = [:]

    func play(_ event: SoundEvent) {
        guard enabled else { return }
        let now = Date()
        if let last = lastPlayed[event], now.timeIntervalSince(last) < 2 { return }
        lastPlayed[event] = now

        guard let sound = customSound(event) ?? event.fallback.flatMap({ NSSound(named: $0)?.copy() as? NSSound }) else { return }
        sound.delegate = self
        playing.append(sound)
        sound.play()
    }

    func play(named name: String?) {
        guard let name, let event = SoundEvent(rawValue: name) else { return }
        play(event)
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        MainActor.assumeIsolated {
            playing.removeAll { $0 === sound }
        }
    }

    private func customSound(_ event: SoundEvent) -> NSSound? {
        var folders = [AppPaths.sounds]
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Sounds") { folders.append(bundled) }
        for folder in folders {
            for ext in Self.extensions {
                let url = folder.appendingPathComponent("\(event.rawValue).\(ext)")
                if FileManager.default.fileExists(atPath: url.path),
                   let sound = NSSound(contentsOf: url, byReference: true) {
                    return sound
                }
            }
        }
        return nil
    }

    static func writeSoundsReadme() {
        let url = AppPaths.sounds.appendingPathComponent("README.txt")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let names = SoundEvent.allCases.map { "  \($0.rawValue)" }.joined(separator: "\n")
        let text = """
        Drop sound files here to replace the system fallbacks.
        Name each file after its event. Supported types: \(extensions.joined(separator: ", ")).

        \(names)
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
