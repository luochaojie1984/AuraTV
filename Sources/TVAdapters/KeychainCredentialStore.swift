import Foundation
import Security

/// Keychain-backed credential storage with an always-updated obfuscated UserDefaults
/// mirror so sideloaded overwrite-installs never lose saved passwords.
public enum KeychainCredentialStore {
    public enum StoreError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain operation failed with status \(status)"
            }
        }
    }

    private static let service = "local.personal.auratv.credentials"
    private static let fallbackPrefix = "local.personal.auratv.cred.fb."

    private static func isFallbackEligible(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement
            || status == errSecNotAvailable
            || status == errSecAuthFailed
            || status == errSecInteractionNotAllowed
    }

    private static func xorMask(_ input: [UInt8], key: String) -> [UInt8] {
        let seed = Array("\(service):\(key)".utf8)
        guard !seed.isEmpty else { return input }
        return input.enumerated().map { index, byte in
            let s = seed[index % seed.count]
            let spin = UInt8((index &* 31) & 0xFF)
            return byte ^ s ^ spin
        }
    }

    private static func encodeFallback(_ password: String, forKey key: String) -> String {
        let masked = xorMask(Array(password.utf8), key: key)
        return Data(masked).base64EncodedString()
    }

    private static func decodeFallback(_ encoded: String, forKey key: String) -> String? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        let unmasked = xorMask(Array(data), key: key)
        return String(bytes: unmasked, encoding: .utf8)
    }

    public static func savePassword(_ password: String, forKey key: String) throws {
        // Always persist obfuscated mirror first so sideload re-signing / overwrite installs retain credentials.
        UserDefaults.standard.set(encodeFallback(password, forKey: key), forKey: fallbackPrefix + key)

        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess || isFallbackEligible(updateStatus) {
            return
        }

        if updateStatus == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            if addStatus == errSecSuccess || isFallbackEligible(addStatus) {
                return
            }
            throw StoreError.unexpectedStatus(addStatus)
        }

        throw StoreError.unexpectedStatus(updateStatus)
    }

    public static func password(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let decoded = String(data: data, encoding: .utf8),
           !decoded.isEmpty {
            if UserDefaults.standard.string(forKey: fallbackPrefix + key) == nil {
                UserDefaults.standard.set(encodeFallback(decoded, forKey: key), forKey: fallbackPrefix + key)
            }
            return decoded
        }
        if let encoded = UserDefaults.standard.string(forKey: fallbackPrefix + key) {
            return decodeFallback(encoded, forKey: key)
        }
        return nil
    }

    @discardableResult
    public static func deletePassword(forKey key: String) -> Bool {
        UserDefaults.standard.removeObject(forKey: fallbackPrefix + key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound || isFallbackEligible(status)
    }

    public static func hasPassword(forKey key: String) -> Bool {
        !(password(forKey: key) ?? "").isEmpty
    }
}
