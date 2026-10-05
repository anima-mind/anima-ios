import Foundation
import Testing
@testable import AnimaKit

// Campo #13: Ajustes → Modelo como UNA fila por provider (sin selectores cruzados).

@Suite("Campo — lista de providers (una fila por provider)")
struct ProviderRosterTests {

    @Test func estadoPorFilaDesdeElKeychainMultiProvider() {
        let rows = ProviderRoster.rows(tokens: [.anthropic: "sk-ant-oat01-x", .google: "AIzaXYZ"],
                                       activeRemote: .anthropic, mode: .hybrid, local: .available)
        #expect(rows.map(\.provider) == [.anthropic, .openai, .google, .onDevice])
        #expect(rows[0].status == "● key guardada · OAuth"); #expect(rows[0].isActive); #expect(rows[0].selectable)
        #expect(rows[1].status == "○ sin key"); #expect(!rows[1].selectable); #expect(rows[1].actionTitle == "Agregar key")
        #expect(rows[2].status == "● key guardada"); #expect(rows[2].authMode == nil); #expect(!rows[2].isActive)
        #expect(rows[2].actionTitle == "Cambiar key")
        #expect(rows[3].status == "● Disponible en este teléfono"); #expect(rows[3].actionTitle == nil)
        #expect(!rows[3].isActive); #expect(rows[3].isReady)
        let api = ProviderRoster.rows(tokens: [.anthropic: "sk-ant-api03-x"], activeRemote: .anthropic,
                                      mode: .remote, local: .available)
        #expect(api[0].status == "● key guardada · API key")
    }

    @Test func localActivoEnSoloTelefonoYNoElegibleConSuPorque() {
        let local = ProviderRoster.rows(tokens: [:], activeRemote: .anthropic, mode: .onDeviceOnly,
                                        local: .available)
        #expect(local.filter(\.isActive).map(\.provider) == [.onDevice])
        let off = ProviderRoster.rows(tokens: [:], activeRemote: .anthropic, mode: .remote,
                                      local: .deviceNotEligible)
        let row = off[3]
        #expect(!row.selectable); #expect(!row.isReady)
        #expect(row.status == "○ Este teléfono no es compatible")
        #expect(row.detail?.contains("Apple Intelligence") == true)
    }

    @Test func borrarLaActivaCaeAlSiguienteConKeyOAlLocal() {
        #expect(ProviderRoster.fallback(afterDeleting: .anthropic, saved: [.google], local: .available) == .google)
        #expect(ProviderRoster.fallback(afterDeleting: .anthropic, saved: [], local: .available) == .onDevice)
        #expect(ProviderRoster.fallback(afterDeleting: .anthropic, saved: [], local: .modelNotReady) == nil)
    }
}

#if canImport(SwiftUI)
@MainActor
@Suite struct SettingsProviderListTests {

    private func makeModel(tokens: [ModelProvider: String] = [:], availability: OnDeviceAvailability = .available)
        throws -> (SettingsViewModel, ProviderTokenStore) {
        let ud = try #require(UserDefaults(suiteName: "test.roster.\(UUID().uuidString)"))
        let keychain = ProviderTokenStore(service: "svc", backend: InMemoryKeychain())
        for (provider, token) in tokens { try keychain.save(token, for: provider) }
        let model = SettingsViewModel(keychain: keychain, telemetry: Telemetry(queue: try AnimaDatabase.temporary()),
                                      onboardingDefaults: OnboardingDefaults(defaults: ud),
                                      availability: { availability })
        model.load()
        return (model, keychain)
    }

    @Test func radioSinKeyAbreElCampoYGuardarHabilitaLaFila() async throws {
        let (model, keychain) = try makeModel(tokens: [.anthropic: "sk-ant-api03-x"])
        var changes: [OperatingMode] = []
        model.onModeChanged = { changes.append($0) }
        #expect(model.rows.first { $0.provider == .google }?.selectable == false)

        model.activate(.google)   // sin key: no activa, abre su campo
        #expect(model.editing == .google)
        #expect(model.remoteProvider == .anthropic)

        model.keyInput = "AIza bad"
        await model.saveKey()
        #expect(model.keyError?.contains("Formato") == true)
        model.keyInput = "AIzaSyTest123"
        await model.saveKey()   // sin apis: acepta offline como el onboarding
        #expect(model.editing == nil); #expect(model.keyError == nil)
        #expect(try keychain.read(.google) == "AIzaSyTest123")
        let google = try #require(model.rows.first { $0.provider == .google })
        #expect(google.status == "● key guardada"); #expect(google.selectable); #expect(!google.isActive)
        #expect(changes.isEmpty)   // no era la activa: no re-cablea

        model.activate(.google)
        #expect(model.remoteProvider == .google)
        #expect(model.rows.first { $0.provider == .google }?.isActive == true)
        #expect(changes.count == 1)
        model.beginEditing(.onDevice)   // el local no tiene key
        #expect(model.editing == nil)
    }

    @Test func localYHibridoConectadosAlModo() throws {
        let (model, _) = try makeModel(tokens: [.anthropic: "sk-ant-api03-x"])
        model.activate(.onDevice)
        #expect(model.mode == .onDeviceOnly)
        #expect(model.rows.last?.isActive == true)
        model.setHybrid(true)   // sin remoto activo: no aplica
        #expect(model.mode == .onDeviceOnly)
        model.activate(.anthropic)   // remota desde Solo teléfono → modo remoto
        #expect(model.mode == .remote)
        model.setHybrid(true)
        #expect(model.mode == .hybrid)
        model.activate(.anthropic)   // ya activa: sin cambios
        #expect(model.mode == .hybrid)
        model.setHybrid(false)
        #expect(model.mode == .remote)
    }

    @Test func borrarLaActivaReSelecciona() throws {
        let (model, keychain) = try makeModel(tokens: [.anthropic: "sk-ant-api03-x", .openai: "sk-proj-x"])
        model.activate(.anthropic)
        model.beginEditing(.anthropic)
        model.deleteKey(.anthropic)
        #expect(try keychain.read(.anthropic) == nil)
        #expect(model.editing == nil)
        #expect(model.remoteProvider == .openai)   // siguiente con key
        #expect(model.rows.first { $0.provider == .openai }?.isActive == true)

        model.deleteKey(.openai)
        #expect(model.mode == .onDeviceOnly)        // sin remotos: el local
        model.deleteKey(.google)                    // sin key / no activa: nada
        model.deleteKey(.onDevice)
        #expect(model.mode == .onDeviceOnly)
    }

    @Test func validacionRechazadaMuestraElPorque() async throws {
        let (model, keychain) = try makeModel()
        model.beginEditing(.openai)
        await model.saveKey()   // vacío: nada
        #expect(model.keyError == nil)
        model.keyInput = "sk-ant-api03-x"
        model.cancelEditing()
        #expect(model.keyInput.isEmpty)
        model.beginEditing(.anthropic)
        model.keyInput = "nope"
        await model.saveKey()
        #expect(model.keyError?.contains("sk-ant") == true)
        #expect(try keychain.read(.anthropic) == nil)
    }
}
#endif
