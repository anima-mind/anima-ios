import Foundation
import Security
import Testing
@testable import AnimaKit

/// Keychain en memoria que imita la semántica de SecItem (clave = service+account,
/// errSecDuplicateItem en add repetido) y registra las queries para asserts.
final class InMemoryKeychain: KeychainBackend, @unchecked Sendable {
    private let items = Locked<[String: Data]>([:])
    let lastAdd = Locked<[String: Any]?>(nil)
    let lastCopy = Locked<[String: Any]?>(nil)
    /// Status forzados para simular fallos de Security.
    var addStatus: OSStatus?
    var copyStatus: OSStatus?
    var deleteStatus: OSStatus?
    /// Devuelve un item no-Data (p. ej. keychain corrupto) en copyMatching.
    var returnGarbage = false

    private func key(_ q: [String: Any]) -> String {
        "\(q[kSecAttrService as String] as? String ?? "")|\(q[kSecAttrAccount as String] as? String ?? "")"
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lastAdd.mutate { $0 = attributes }
        if let addStatus { return addStatus }
        let k = key(attributes)
        return items.mutate { items -> OSStatus in
            if items[k] != nil { return errSecDuplicateItem }
            items[k] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        lastCopy.mutate { $0 = query }
        if let copyStatus { return (copyStatus, nil) }
        if returnGarbage { return (errSecSuccess, "no-data" as CFString) }
        guard let data = items.value[key(query)] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data as CFData)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        if let deleteStatus { return deleteStatus }
        return items.mutate { $0.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess }
    }
}

@Suite struct KeychainStoreTests {

    @Test func saveThenReadRoundTrips() throws {
        let store = KeychainStore(service: "svc", backend: InMemoryKeychain())
        #expect(try store.read() == nil)
        try store.save("sk-ant-api03-abc")
        #expect(try store.read() == "sk-ant-api03-abc")
    }

    @Test func saveIsUpsertReplacingPreviousToken() throws {
        // Sin el delete previo, el segundo add daría errSecDuplicateItem.
        let store = KeychainStore(service: "svc", backend: InMemoryKeychain())
        try store.save("viejo")
        try store.save("nuevo")
        #expect(try store.read() == "nuevo")
    }

    @Test func saveUsesGenericPasswordAfterFirstUnlock() throws {
        let backend = InMemoryKeychain()
        try KeychainStore(service: "svc", account: "acct", backend: backend).save("t")
        let attrs = try #require(backend.lastAdd.value)
        #expect(attrs[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(attrs[kSecAttrService as String] as? String == "svc")
        #expect(attrs[kSecAttrAccount as String] as? String == "acct")
        #expect(attrs[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(attrs[kSecValueData as String] as? Data == Data("t".utf8))
    }

    @Test func readAsksForSingleItemData() throws {
        let backend = InMemoryKeychain()
        _ = try KeychainStore(service: "svc", backend: backend).read()
        let q = try #require(backend.lastCopy.value)
        #expect(q[kSecReturnData as String] as? Bool == true)
        #expect(q[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
    }

    @Test func accountsAreIsolated() throws {
        let backend = InMemoryKeychain()
        let a = KeychainStore(service: "svc", account: "a", backend: backend)
        let b = KeychainStore(service: "svc", account: "b", backend: backend)
        try a.save("token-a")
        #expect(try b.read() == nil)
        #expect(try a.read() == "token-a")
    }

    @Test func deleteRemovesAndIsIdempotent() throws {
        let store = KeychainStore(service: "svc", backend: InMemoryKeychain())
        try store.save("t")
        try store.delete()
        #expect(try store.read() == nil)
        try store.delete()  // errSecItemNotFound no es error
    }

    @Test func surfacesUnexpectedStatuses() throws {
        let backend = InMemoryKeychain()
        let store = KeychainStore(service: "svc", backend: backend)

        backend.addStatus = errSecInteractionNotAllowed
        #expect(throws: KeychainStore.KeychainError.unexpectedStatus(errSecInteractionNotAllowed)) {
            try store.save("t")
        }
        backend.copyStatus = errSecAuthFailed
        #expect(throws: KeychainStore.KeychainError.unexpectedStatus(errSecAuthFailed)) {
            _ = try store.read()
        }
        backend.deleteStatus = errSecInteractionNotAllowed
        #expect(throws: KeychainStore.KeychainError.unexpectedStatus(errSecInteractionNotAllowed)) {
            try store.delete()
        }
    }

    @Test func nonDataItemReadsAsMissing() throws {
        let backend = InMemoryKeychain()
        backend.returnGarbage = true
        #expect(try KeychainStore(service: "svc", backend: backend).read() == nil)
    }
}
