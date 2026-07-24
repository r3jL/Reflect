// API key storage (FR-013, §3.4): secrets live in the macOS Keychain,
// never in the database. The settings table only ever records that a key
// exists, not the material itself.
import Foundation
import Security

enum KeychainStore {
    private static let service = "com.rejul.reflect"

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }

    // In-memory cache: at most one keychain ACL check per launch. macOS
    // prompts once per (binary, item) — with ad-hoc dev signing the binary
    // identity changes every rebuild, so without this every keychain read
    // path could prompt; with it, it's a single prompt per session at most.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String??] = [:]

    /// Cached read — preferred for hot paths (pipeline gates, providers).
    static func cachedGet(account: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[account] {
            return hit ?? nil
        }
        let value = get(account: account)
        cache[account] = .some(value)
        return value
    }

    private static func invalidate(account: String) {
        cacheLock.lock()
        cache[account] = nil
        cacheLock.unlock()
    }

    static func set(_ value: String, account: String) throws {
        defer { invalidate(account: account) }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(
            query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        defer { invalidate(account: account) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Well-known accounts.
    static let openRouterKeyAccount = "openrouter-api-key"
}
