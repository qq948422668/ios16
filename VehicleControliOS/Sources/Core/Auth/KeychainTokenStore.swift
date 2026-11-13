import Foundation
import Security

/// Keychain 存储凭证，替代 Android 侧 SharedPreferences/MMKV 的明文落盘。
/// 使用 AfterFirstUnlock + ThisDeviceOnly：后台刷新可用，且不随 iCloud 备份迁移。
final class KeychainTokenStore: TokenStoring, @unchecked Sendable {
    private let service: String
    private let account: String
    private let lock = NSLock()

    init(service: String, account: String = "oauth.session") {
        self.service = service
        self.account = account
    }

    func load() -> TokenPair? {
        lock.lock()
        defer { lock.unlock() }

        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONCoding.decode(TokenPair.self, from: data)
    }

    func save(_ pair: TokenPair) throws {
        lock.lock()
        defer { lock.unlock() }

        let data = try JSONCoding.encode(pair)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insertQuery = baseQuery
            insertQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Keychain 操作失败（OSStatus \(status)）" }
}
