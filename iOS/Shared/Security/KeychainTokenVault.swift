import Foundation
import Security

public protocol TokenVault: Sendable {
    func token(for toolID: UUID) throws -> String?
    func save(_ token: String, for toolID: UUID) throws
    func deleteToken(for toolID: UUID) throws
    func storedToolIDs() throws -> Set<UUID>
}

public enum KeychainTokenVaultError: Error, Equatable, LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidTokenData

    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return detail ?? "Keychain operation failed with status \(status)."
        case .invalidTokenData:
            return "The saved bearer token is not valid UTF-8."
        }
    }
}

/// Stores remote endpoint bearer tokens outside preferences and shared caches.
/// Tokens stay app-private; the widget consumes only sanitized quota snapshots.
public struct KeychainTokenVault: TokenVault, Sendable {
    public let service: String
    public let accessGroup: String?

    public init(
        service: String = "com.richardq.usaige.remote-tools",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func token(for toolID: UUID) throws -> String? {
        var query = baseQuery(for: toolID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainTokenVaultError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw KeychainTokenVaultError.invalidTokenData
        }
        return token
    }

    public func save(_ token: String, for toolID: UUID) throws {
        if token.isEmpty {
            try deleteToken(for: toolID)
            return
        }

        let tokenData = Data(token.utf8)
        let query = baseQuery(for: toolID)
        let updates: [String: Any] = [kSecValueData as String: tokenData]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = tokenData
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainTokenVaultError.unexpectedStatus(addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw KeychainTokenVaultError.unexpectedStatus(updateStatus)
        }
    }

    public func deleteToken(for toolID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: toolID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenVaultError.unexpectedStatus(status)
        }
    }

    /// Returns only account identifiers for this app's token service. Token
    /// bytes never leave Keychain during orphan reconciliation.
    public func storedToolIDs() throws -> Set<UUID> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw KeychainTokenVaultError.unexpectedStatus(status)
        }

        let attributes: [[String: Any]]
        if let values = result as? [[String: Any]] {
            attributes = values
        } else if let value = result as? [String: Any] {
            attributes = [value]
        } else {
            return []
        }

        return Set(attributes.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else {
                return nil
            }
            return UUID(uuidString: account)
        })
    }

    private func baseQuery(for toolID: UUID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: toolID.uuidString.lowercased(),
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
