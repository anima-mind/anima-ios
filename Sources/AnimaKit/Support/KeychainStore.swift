// KeychainStore.swift — token del provider en Keychain (plan doc 04 §8).
// La API key / OAuth token JAMÁS en código, plist ni UserDefaults.
// Accesibilidad: AfterFirstUnlock (disponible tras el primer desbloqueo del
// dispositivo, sobrevive relanzamientos en background para BGTask), sin sync a
// iCloud (ThisDeviceOnly implícito por seguridad del perfil edge).

import Foundation
import Security

public struct KeychainStore: Sendable {
    private let service: String
    private let account: String

    public init(service: String = "dev.joshua.anima.provider-token",
                account: String = "default") {
        self.service = service
        self.account = account
    }

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case encodingFailed
    }

    /// Guarda (o reemplaza) el token.
    public func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw KeychainError.encodingFailed }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)  // upsert: borra el previo si existe

        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Lee el token; nil si no existe.
    public func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    /// Borra el token.
    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
