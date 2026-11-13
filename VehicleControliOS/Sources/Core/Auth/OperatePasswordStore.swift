import Foundation
import Security

/// 4 位操作密码：官方控车矩阵中 35+ 指令均要求携带 `oppwd`
/// （AES-128-CBC 加密后随表单提交）。本地仅存 Keychain，不落明文。
enum OperatePasswordStore {
    private static let service = "com.vehiclecontrol.app.control"
    private static let account = "operate.pin"
    private static let lock = NSLock()

    static func load() -> String? {
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
        return String(data: data, encoding: .utf8)
    }

    static func save(_ pin: String) {
        guard isValid(pin) else { return }
        lock.lock()
        defer { lock.unlock() }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(pin.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertQuery = baseQuery
            insertQuery.merge(attributes) { _, new in new }
            SecItemAdd(insertQuery as CFDictionary, nil)
        }
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(baseQuery as CFDictionary)
    }

    static func isValid(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy(\.isNumber)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
