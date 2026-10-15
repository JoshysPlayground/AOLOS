import Foundation
import Security

struct SavedCredential: Equatable {
    let account: String
    let password: String
}

/// Site logins are internet-password items in the login keychain, so they also appear in Keychain Access.
enum Keychain {
    private static let secretService = "com.aolos.app"

    static func credential(forHost host: String) -> SavedCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return nil }
        return SavedCredential(account: item[kSecAttrAccount as String] as? String ?? "", password: password)
    }

    @discardableResult
    static func save(host: String, account: String, password: String) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrLabel as String: "\(host) (AOL-OS)",
        ]
        var status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(match.merging(attributes) { $1 } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    /// All app secrets live in one generic-password item as a JSON object, read once per launch.
    /// macOS asks for Keychain access per item, so one item means at most one prompt.
    private static let storeAccount = "secrets"
    private static let legacyKeys = [
        "google.clientID", "google.clientSecret", "google.refreshToken", "google.email",
        "spotify.clientID", "spotify.refreshToken", "spotify.user",
    ]
    nonisolated(unsafe) private static var cache: [String: String]?

    static func secret(_ key: String) -> String? {
        loadStore()[key]
    }

    @discardableResult
    static func setSecret(_ key: String, _ value: String?) -> Bool {
        var store = loadStore()
        guard store[key] != value else { return true }
        store[key] = value
        cache = store
        return writeItem(storeAccount, try? JSONEncoder().encode(store))
    }

    private static func loadStore() -> [String: String] {
        if let cache { return cache }
        var store: [String: String] = [:]
        if let data = readItem(storeAccount), let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            store = decoded
        } else {
            for key in legacyKeys {
                if let data = readItem(key), let value = String(data: data, encoding: .utf8) { store[key] = value }
            }
            if !store.isEmpty, writeItem(storeAccount, try? JSONEncoder().encode(store)) {
                legacyKeys.forEach { writeItem($0, nil) }
            }
        }
        cache = store
        return store
    }

    private static func readItem(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: secretService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private static func writeItem(_ account: String, _ data: Data?) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: secretService,
            kSecAttrAccount as String: account,
        ]
        guard let data else {
            let status = SecItemDelete(match as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(match.merging(attributes) { $1 } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}
