import Foundation
import Security

/// Keychain store for the accounts blob and backup/WebDAV secrets.
enum Keychain {
    private static let service = "app.authvault.secrets"

    static func setData(_ data: Data, for key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func getData(_ key: String) -> Data? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service, kSecAttrAccount as String: key]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    static func set(_ value: String, for key: String) { setData(Data(value.utf8), for: key) }
    static func get(_ key: String) -> String { getData(key).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
}
