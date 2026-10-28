import Foundation
import Security

enum TokenVault {
    private static let service = "dev.evergreen.embryo.gateway"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "dsw-evergreen", kSecAttrSynchronizable as String: false]
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError(status: status) }
    }
    struct VaultError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain unavailable (\(status)). Unlock the device and try again." }
    }
}
