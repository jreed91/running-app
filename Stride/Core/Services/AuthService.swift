import AuthenticationServices
import Foundation
import Security

// MARK: - AuthService

@MainActor
@Observable
final class AuthService {

    private(set) var isSignedIn: Bool
    private(set) var appleUserID: String?
    var welcomeBackPending: Bool = false

    private static let keychainService = "com.running.stride"
    private static let keychainAccount = "appleUserID"

    init() {
        let stored = Self.loadFromKeychain()
        appleUserID = stored
        isSignedIn = stored != nil
        // `await self?.listenForRevocation()` looks weak but isn't: the optional chain
        // resolves once and the call then holds a strong `self` for the lifetime of an
        // infinite `for await`, so the service could never deallocate (N30). Iterating
        // here and re-checking `self` each time — the shape
        // `AppSettings.observeExternalChanges` uses — actually keeps it weak.
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: ASAuthorizationAppleIDProvider.credentialRevokedNotification
            ) {
                guard let self else { return }
                self.signOutSilently()
            }
        }
    }

    // MARK: - Public API

    func checkCredentialState() async {
        guard let userID = appleUserID else { return }
        do {
            let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID)
            if state == .revoked || state == .notFound {
                signOutSilently()
            }
        } catch {
            // Network error — keep the user signed in until state can be confirmed
        }
    }

    func handleSignIn(userID: String) {
        Self.saveToKeychain(userID)
        appleUserID = userID
        isSignedIn = true
    }

    func signOut() {
        Self.deleteFromKeychain()
        appleUserID = nil
        isSignedIn = false
    }

    // MARK: - Private

    private func signOutSilently() {
        Self.deleteFromKeychain()
        appleUserID = nil
        isSignedIn = false
        welcomeBackPending = false
    }

    // MARK: - Keychain

    private static func loadFromKeychain() -> String? {
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
        return String(data: data, encoding: .utf8)
    }

    private static func saveToKeychain(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
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
