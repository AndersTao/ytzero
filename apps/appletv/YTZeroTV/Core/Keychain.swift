import Foundation
import Security

/// The device session token, kept in the Keychain rather than in defaults.
///
/// On iPhone and iPad the items are written into the App Group
/// (`SharedStore.appGroup`), so the Safari and Share extensions can read the
/// session too. Reads and deletes look in every group the app may use, which
/// also finds an item saved before the group existed.
nonisolated enum Keychain {
    private static let service = "app.ytzero.appletv.session"

    static func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account: account)
        var query = baseQuery(account: account)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecValueData as String] = Data(value.utf8)
        if let group = SharedStore.appGroup {
            var shared = query
            shared[kSecAttrAccessGroup as String] = group
            // A build signed without the group (the simulator without a
            // team) cannot write there; the app keeps the item to itself.
            if SecItemAdd(shared as CFDictionary, nil) == errSecSuccess { return }
        }
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    /// Whether the extensions can read the item: true when it is in the
    /// group, and when there is no group to share.
    static func isShared(account: String) -> Bool {
        guard let group = SharedStore.appGroup else { return true }
        var query = baseQuery(account: account)
        query[kSecAttrAccessGroup as String] = group
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
