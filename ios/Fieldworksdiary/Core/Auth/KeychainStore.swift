import Foundation
import Security

/// Minimal wrapper around the iOS Keychain for storing the PocketBase
/// auth token (and any future auth-related secret).
///
/// The Keychain entries are scoped to our service identifier so they
/// don't collide with other apps. We use `kSecAttrAccessibleAfterFirstUnlock`
/// so the token is readable once the user has unlocked the device
/// since the last reboot — that matches "session lives across app
/// restarts but not across cold-boots until login" semantics.
struct KeychainStore {
    let service: String

    static let `default` = KeychainStore(service: "com.weevilapp.Weevilapp.auth")

    func setString(_ value: String, forKey key: String) {
        delete(key: key)
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func string(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func clear() {
        for key in [Keys.token, Keys.userId, Keys.email] {
            delete(key: key)
        }
    }

    enum Keys {
        static let token  = "auth_token"
        static let userId = "auth_user_id"
        static let email  = "auth_email"
    }
}
