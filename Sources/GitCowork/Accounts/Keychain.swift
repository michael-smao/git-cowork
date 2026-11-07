import Foundation
import GitCoworkCore
import Security

/// Tokens in the login keychain, one item per host.
enum Keychain {
    private static let service = "git-cowork"

    private static func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: host]
    }

    /// Updates the host's item in place, or adds one. The old token stays
    /// until the new one is safely stored.
    @discardableResult
    static func save(_ data: Data, host: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "git-cowork: \(host)",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(host) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        let item = query(host).merging(attributes) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func load(host: String) -> Data? {
        var q = query(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(host: String) {
        SecItemDelete(query(host) as CFDictionary)
    }

    // MARK: Tokens (stored as JSON)

    @discardableResult
    static func saveTokens(_ tokens: TokenSet, host: String) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return save(data, host: host)
    }

    static func loadTokens(host: String) -> TokenSet? {
        load(host: host).flatMap { try? JSONDecoder().decode(TokenSet.self, from: $0) }
    }
}
