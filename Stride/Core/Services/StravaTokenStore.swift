import Foundation
import Observation
import Security

// MARK: - StravaTokens

struct StravaTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var athleteName: String?

    /// Treats tokens expiring within five minutes as stale so we refresh ahead of time.
    func isExpired(now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) < 300
    }
}

// MARK: - StravaTokenStore

/// Persists Strava OAuth tokens in the Keychain and exposes connection state to the UI.
@MainActor
@Observable
final class StravaTokenStore {

    private(set) var tokens: StravaTokens?

    var isConnected: Bool { tokens != nil }
    var athleteName: String? { tokens?.athleteName }

    private static let keychainService = "com.running.stride"
    private static let keychainAccount = "stravaTokens"

    init() {
        tokens = Self.loadFromKeychain()
    }

    func save(_ tokens: StravaTokens) {
        self.tokens = tokens
        Self.saveToKeychain(tokens)
    }

    func clear() {
        tokens = nil
        Self.deleteFromKeychain()
    }

    // MARK: - Keychain

    private static func loadFromKeychain() -> StravaTokens? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StravaTokens.self, from: data)
    }

    private static func saveToKeychain(_ tokens: StravaTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private static func deleteFromKeychain() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
