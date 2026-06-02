import Foundation
import Security

final class CloudServerTokenStore {
    static let shared = CloudServerTokenStore()

    private let service = "com.mc-ssh.cloud-api-token"

    private init() {}

    func saveToken(_ token: String, account: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw CloudServerTokenStoreError.encodingFailed
        }

        let query = baseQuery(account: account)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CloudServerTokenStoreError.keychainStatus(updateStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CloudServerTokenStoreError.keychainStatus(status)
        }
    }

    func loadToken(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CloudServerTokenStoreError.keychainStatus(status)
        }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw CloudServerTokenStoreError.encodingFailed
        }
        return token
    }

    func deleteToken(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudServerTokenStoreError.keychainStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum CloudServerTokenStoreError: LocalizedError {
    case encodingFailed
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Cloud API token could not be encoded."
        case .keychainStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain returned status \(status)."
        }
    }
}
