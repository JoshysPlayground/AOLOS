import AppKit
import CryptoKit
import WebKit

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("AOL-OS", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let sounds: URL = {
        let url = support.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var config: URL { support.appendingPathComponent("config.json") }

    /// Looks for a branding image in Application Support first, then in the app bundle.
    static func brandingImage(_ name: String) -> NSImage? {
        var candidates = [support.appendingPathComponent("Branding/\(name)")]
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Branding/\(name)") { candidates.append(bundled) }
        return candidates.lazy.compactMap { NSImage(contentsOf: $0) }.first
    }
}

extension UUID {
    /// WebKit persists a data store by UUID, so the same profile name must always map to the same UUID.
    static func stable(_ name: String) -> UUID {
        var b = Array(SHA256.hash(data: Data("aol-os.profile.\(name)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

@MainActor
enum DataStores {
    private static var cache: [String: WKWebsiteDataStore] = [:]

    static func store(for profile: String) -> WKWebsiteDataStore {
        if let store = cache[profile] { return store }
        let store = WKWebsiteDataStore(forIdentifier: UUID.stable(profile))
        cache[profile] = store
        return store
    }
}

final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
         _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

final class ActionTextField: NSTextField {
    var onSubmit: ((String) -> Void)?

    convenience init(placeholder: String) {
        self.init(frame: .zero)
        placeholderString = placeholder
        font = Theme.ui(12)
        bezelStyle = .squareBezel
        isBezeled = true
        target = self
        action = #selector(submit)
        (cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
    }

    @objc private func submit() { onSubmit?(stringValue) }
}

@MainActor
enum Prompt {
    static func text(title: String, message: String, placeholder: String = "",
                     initial: String = "", confirm: String = "OK") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
