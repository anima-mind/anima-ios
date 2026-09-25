// KeychainStore.swift — token del provider en Keychain (plan doc 04 §8).
// La API key / OAuth token JAMÁS en código, plist ni UserDefaults.
// Accesibilidad: AfterFirstUnlock (disponible tras el primer desbloqueo del
// dispositivo, sobrevive relanzamientos en background para BGTask), sin sync a
// iCloud (ThisDeviceOnly implícito por seguridad del perfil edge).

import Foundation
import Security

/// Las tres llamadas SecItem que usa el store. En producción van directo a
/// Security; los tests inyectan un keychain en memoria (CI sin keychain desbloqueado).
protocol KeychainBackend: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainBackend: KeychainBackend {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

public struct KeychainStore: Sendable {
    private let service: String
    private let account: String
    private let backend: KeychainBackend

    public init(service: String = "dev.joshua.anima.provider-token",
                account: String = "default") {
        self.init(service: service, account: account, backend: SystemKeychainBackend())
    }

    init(service: String, account: String = "default", backend: KeychainBackend) {
        self.service = service
        self.account = account
        self.backend = backend
    }

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case encodingFailed
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Guarda (o reemplaza) el token.
    public func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw KeychainError.encodingFailed }
        _ = backend.delete(baseQuery)  // upsert: borra el previo si existe

        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = backend.add(attrs)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Lee el token; nil si no existe.
    public func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = backend.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    /// Borra el token.
    public func delete() throws {
        let status = backend.delete(baseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
