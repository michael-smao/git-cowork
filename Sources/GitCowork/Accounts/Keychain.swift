import Foundation
import GitCoworkCore
import Security

/// Tokens in the login keychain, one item per account.
enum Keychain {
    private static let service = "git-cowork"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    /// Updates the item in place, or adds one. The old token stays until the
    /// new one is safely stored.
    @discardableResult
    private static func save(_ data: Data, key: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "git-cowork: \(key)",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        let item = query(key).merging(attributes) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func load(key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func delete(key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }

    static func delete(_ account: HostAccount) {
        delete(key: account.id)
    }

    /// Items used to be named after the host alone, back when a host had one
    /// account. Hands each to its account. Host names never contain "@", so
    /// the two kinds of names can't collide.
    static func moveHostItems(to accounts: [HostAccount]) {
        for host in Set(accounts.map(\.host)) {
            guard let data = load(key: host) else { continue }
            if let owner = accounts.first(where: { $0.host == host }), load(key: owner.id) == nil {
                guard save(data, key: owner.id) else { continue }
            }
            delete(key: host)
        }
    }

    // MARK: Tokens (stored as JSON)

    @discardableResult
    static func saveTokens(_ tokens: TokenSet, for account: HostAccount) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return save(data, key: account.id)
    }

    static func loadTokens(for account: HostAccount) -> TokenSet? {
        load(key: account.id).flatMap { try? JSONDecoder().decode(TokenSet.self, from: $0) }
    }
}
