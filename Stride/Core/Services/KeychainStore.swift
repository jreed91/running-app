import Foundation
import Security

/// Minimal generic-password Keychain wrapper for small on-device secrets (API tokens).
///
/// Unlike `UserDefaults` or `NSUbiquitousKeyValueStore`, values stored here are never
/// written to the app's plist and never synced through iCloud, so secrets stay on the
/// device that owns them. Items use `AfterFirstUnlockThisDeviceOnly` accessibility:
/// readable in the background after the first unlock, and excluded from encrypted
/// backups / device migration.
enum KeychainStore {
    private static let service = "com.running.stride"

    static func string(for account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value` for `account`. Passing `nil` or an empty string deletes the item,
    /// so callers can treat "cleared secret" and "delete" uniformly.
    static func set(_ value: String?, for account: String) {
        guard let value, !value.isEmpty else {
            delete(account)
            return
        }
        guard let data = value.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
