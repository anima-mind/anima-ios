import Foundation
import Testing
@testable import AnimaKit

// Sin hardware en CI, la bitácora de Ajustes → Gafas →
// Diagnóstico es lo que el dueño pega cuando algo falla en las gafas.

@Suite("Campo — diagnóstico copiable de las gafas")
struct GlassesDiagnosticsTests {

    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func guardaLosUltimosNEnOrden() {
        let diag = GlassesDiagnostics(capacity: 3, now: { Self.epoch })
        for i in 1...5 { diag.record(.photo, "e\(i)") }
        #expect(diag.entries.map(\.message) == ["e3", "e4", "e5"])
        #expect(diag.entries.allSatisfy { $0.category == .photo })
        diag.clear()
        #expect(diag.entries.isEmpty)
        #expect(GlassesDiagnostics(capacity: 0).capacity == 1)
        #expect(GlassesDiagnostics().capacity == 30)
    }

    @Test func reporteConCabeceraYUnaLineaPorEvento() {
        let diag = GlassesDiagnostics(now: { Self.epoch })
        let empty = diag.report(header: ["Estado: x"]).components(separatedBy: "\n")
        #expect(empty == ["Anima · diagnóstico de gafas", "Estado: x", "— sin eventos —"])
        diag.record(.audio, "settle hfp 420 ms")
        let report = diag.report(header: ["Estado: x"])
        let lines = report.components(separatedBy: "\n")
        #expect(lines.first == "Anima · diagnóstico de gafas")
        #expect(lines.contains("Estado: x"))
        #expect(lines.contains("— último evento —"))
        let last = try? #require(lines.last)
        #expect(last?.hasSuffix("[audio] settle hfp 420 ms") == true)
        #expect(last?.count == "HH:mm:ss.SSS".count + " [audio] settle hfp 420 ms".count)
        diag.record(.photo, "captura iniciada")
        let two = diag.report(header: []).components(separatedBy: "\n")
        #expect(two.contains("— últimos 2 eventos, el más reciente primero —"))
        #expect(two.suffix(2).map { String($0.dropFirst("HH:mm:ss.SSS ".count)) }
                == ["[photo] captura iniciada", "[audio] settle hfp 420 ms"])
    }

    @Test func conteoDeEventosEnSingularYPlural() {
        #expect(GlassesDiagnostics.eventCount(0) == "0 eventos")
        #expect(GlassesDiagnostics.eventCount(1) == "1 evento")
        #expect(GlassesDiagnostics.eventCount(2) == "2 eventos")
    }

    @Test func laHoraUsaUnSoloFormatoEstable() {
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        let first = GlassesDiagnostics.timestamp(date)
        #expect(first.count == "HH:mm:ss.SSS".count)
        #expect(first.hasSuffix(".250"))
        #expect(GlassesDiagnostics.timestamp(date) == first)
    }

    @Test func elStreamEmiteElActualYCadaCambio() async {
        let diag = GlassesDiagnostics()
        diag.record(.hud, "a")
        var iterator = diag.updates().makeAsyncIterator()
        #expect(await iterator.next()?.map(\.message) == ["a"])
        diag.record(.hud, "b")
        #expect(await iterator.next()?.map(\.message) == ["a", "b"])
        diag.clear()
        #expect(await iterator.next()?.isEmpty == true)
    }

    @Test func elCuerpoAnotaSesionDisplayFallosYEnlace() async throws {
        let runtime = MockRuntime()
        let diag = GlassesDiagnostics()
        let body = GlassesBody(runtime: runtime, diagnostics: diag)
        await body.start()
        runtime.setDevices([MockRuntime.display])
        #expect(await eventually { await body.currentStatus().body == .dormant })
        try await body.ensureActive()
        #expect(await body.waitUntilActive())
        runtime.lastSession?.fault(.compatibilityWarning)
        #expect(await eventually { diag.entries.contains { $0.category == .fault } })
        let status = await body.currentStatus()
        #expect(status.link == .connected)
        #expect(status.compatibility == .compatible)
        #expect(status.sessionState == .started)
        #expect(status.displayState == .started)
        let categories = Set(diag.entries.map(\.category))
        #expect(categories.isSuperset(of: [.link, .compat, .session, .display, .fault]))
        await body.teardown()
        #expect(diag.entries.last?.message.contains("teardown") == true
                || diag.entries.contains { $0.message.contains("teardown") })
        #expect(await body.currentStatus().sessionState == nil)
    }

    @Test func actualizacionesAbrenMetaAIYQuedanAnotadas() async throws {
        let runtime = MockRuntime()
        let diag = GlassesDiagnostics()
        let body = GlassesBody(runtime: runtime, diagnostics: diag)
        try await body.openFirmwareUpdate()
        try await body.openDATGlassesAppUpdate()
        #expect(runtime.firmwareCalls.value == 1)
        #expect(runtime.updateCalls.value == 1)
        #expect(diag.entries.map(\.message) == ["abrir actualización de firmware", "abrir actualización de la app DAT"])
        await #expect(throws: AbsentGlassesRuntime.Unavailable.self) {
            try await AbsentGlassesRuntime().openFirmwareUpdate()
        }
    }

    @Test func configureFallidoQuedaComoError() async {
        let diag = GlassesDiagnostics()
        let body = GlassesBody(runtime: MockRuntime(configureError: MockError("sin MetaAppID")), diagnostics: diag)
        await body.start()
        #expect(diag.entries.first?.category == .error)
        #expect(diag.entries.first?.message.contains("sin MetaAppID") == true)
    }

    @Test func errorDeEnvioAlDisplayQuedaAnotado() async throws {
        let runtime = MockRuntime()
        let display = MockDisplay()
        display.sendError.mutate { $0 = MockError("bt caído") }
        runtime.nextSession.mutate { $0 = { MockSession(display: display) } }
        let diag = GlassesDiagnostics()
        let body = GlassesBody(runtime: runtime, diagnostics: diag)
        await body.start()
        runtime.setDevices([MockRuntime.display])
        _ = await eventually { await body.currentStatus().body == .dormant }
        try await body.ensureActive()
        _ = await body.waitUntilActive()
        await body.render(HUDRenderer.render(.home(status: nil)))
        #expect(diag.entries.contains { $0.category == .error && $0.message.contains("display.send(home)") })
    }
}

/// Serializada: es la ÚNICA suite que escribe `HUDIconPolicy.mode` (global).
@Suite("Campo — Ajustes → Gafas: estado, acciones y diagnóstico", .serialized)
@MainActor
struct GlassesSettingsModelTests {

    static func defaults() -> UserDefaults {
        let name = "glasses-settings-\(UUID().uuidString)"
        return UserDefaults(suiteName: name) ?? .standard
    }

    @Test func filasDeEstadoYReporteCopiable() async {
        let runtime = MockRuntime()
        let diag = GlassesDiagnostics()
        let body = GlassesBody(runtime: runtime, diagnostics: diag)
        await body.start()
        runtime.setDevices([GlassesDeviceSnapshot(id: "g1", name: "Meta Ray-Ban Display", link: .connected,
                                                  compatibility: .compatible, batteryPercent: 64,
                                                  deviceType: .metaRayBanDisplay, thermal: .normal)])
        let model = GlassesViewModel(body: body, activation: nil, defaults: Self.defaults())
        #expect(await eventually { await MainActor.run { model.status.batteryPercent == 64 } })
        let rows = Dictionary(uniqueKeysWithValues: model.statusRows.map { ($0.id, $0.value) })
        #expect(rows["sdk"] == "1.0.0")
        #expect(rows["link"] == "conectadas")
        #expect(rows["compat"] == "compatible")
        #expect(rows["battery"] == "64%")
        #expect(rows["model"] == "Meta Ray-Ban Display")
        #expect(rows["thermal"] == "normal")
        #expect(rows["versions"] == "el SDK no expone sus versiones")
        #expect(await eventually { await MainActor.run { !model.diagnosticEntries.isEmpty } })
        let report = model.diagnosticReport
        #expect(report.contains("SDK DAT: 1.0.0"))
        #expect(report.contains("Iconos: auto"))
        #expect(report.contains("[link]"))
        #expect(report.contains("Modelo: Meta Ray-Ban Display"))
        #expect(report.contains("Temperatura: normal"))
        model.copyDiagnostics()
        let count = model.diagnosticEntries.count
        #expect(model.notice == "Diagnóstico copiado (\(GlassesDiagnostics.eventCount(count))).")
        #expect(model.diagnosticLines.count == count)
        // Pantalla y texto copiado en el MISMO orden: el más reciente primero.
        #expect(model.diagnosticLines.first == model.diagnosticEntries.last.map(GlassesDiagnostics.line))
        let reportLines = model.diagnosticReport.components(separatedBy: "\n")
        #expect(Array(reportLines.suffix(model.diagnosticLines.count)) == model.diagnosticLines)
    }

    @Test func copiarUnSoloEventoVaEnSingular() {
        let diag = GlassesDiagnostics()
        diag.record(.hud, "a")
        let model = GlassesViewModel(body: nil, activation: nil, defaults: Self.defaults(), diagnostics: diag)
        #expect(model.diagnosticReport.contains("— último evento —"))
    }

    @Test func temperaturaYModeloEnEspanolLegible() {
        let thermal: [GlassesThermal: String] = [
            .unknown: "desconocida", .normal: "normal", .light: "leve", .moderate: "moderada",
            .severe: "alta", .critical: "crítica", .emergency: "emergencia", .shutdown: "apagado",
        ]
        #expect(thermal.count == GlassesThermal.allCases.count)
        for (level, label) in thermal { #expect(GlassesViewModel.thermalLabel(level) == label) }
        #expect(GlassesViewModel.modelLabel(.metaRayBanDisplay) == "Meta Ray-Ban Display")
        #expect(GlassesViewModel.modelLabel(.rayBanMeta) == "Ray-Ban Meta")
        #expect(GlassesViewModel.modelLabel(.oakleyMetaHSTN) == "Oakley Meta HSTN")
        #expect(GlassesViewModel.modelLabel(.oakleyMetaVanguard) == "Oakley Meta Vanguard")
        #expect(GlassesViewModel.modelLabel(.rayBanMetaOptics) == "Ray-Ban Meta Optics")
        #expect(GlassesViewModel.modelLabel(.metaGlasses) == "Gafas Meta")
        #expect(GlassesViewModel.modelLabel(.unknown) == "desconocido")
        for model in GlassesModel.allCases {
            #expect(GlassesViewModel.modelLabel(model) != model.rawValue)
        }
    }

    @Test func etiquetasDeEnlaceYCompatibilidad() {
        #expect(GlassesViewModel.linkLabel(nil) == "sin gafas a la vista")
        #expect(GlassesViewModel.linkLabel(.connecting) == "conectando…")
        #expect(GlassesViewModel.linkLabel(.disconnected) == "desconectadas")
        #expect(GlassesViewModel.compatibilityLabel(.deviceUpdateRequired).contains("actualiza"))
        #expect(GlassesViewModel.compatibilityLabel(.sdkUpdateRequired).contains("SDK"))
        #expect(GlassesViewModel.compatibilityLabel(nil) == "sin confirmar")
    }

    @Test func firmwareYDATSiempreDisponiblesSinGafasAvisan() async {
        let runtime = MockRuntime()
        let body = GlassesBody(runtime: runtime)
        let model = GlassesViewModel(body: body, activation: nil, defaults: Self.defaults())
        model.openFirmwareUpdate()
        model.openDATUpdate()
        #expect(await eventually { runtime.firmwareCalls.value == 1 && runtime.updateCalls.value == 1 })
        let none = GlassesViewModel(body: nil, activation: nil, defaults: Self.defaults())
        none.openFirmwareUpdate()
        #expect(none.notice == "Las gafas no están disponibles en esta build.")
        none.openDATUpdate()
        #expect(none.notice == "Las gafas no están disponibles en esta build.")
    }

    @Test func elModoGlobalSeLeeYSeEscribe() {
        let before = HUDIconPolicy.mode
        defer { HUDIconPolicy.mode = before }
        for mode in HUDIconMode.allCases {
            HUDIconPolicy.mode = mode
            #expect(HUDIconPolicy.mode == mode)
            #expect(!mode.label.isEmpty)
        }
    }

    @Test func modoDeIconosPersisteYAplicaLaPolitica() {
        let before = HUDIconPolicy.mode
        defer { HUDIconPolicy.mode = before }
        let defaults = Self.defaults()
        let model = GlassesViewModel(body: nil, activation: nil, defaults: defaults)
        #expect(model.iconMode == .auto)
        model.setIconMode(.text)
        #expect(HUDIconPolicy.mode == .text)
        #expect(defaults.string(forKey: HUDIconPolicy.modeKey) == "text")
        let reloaded = GlassesViewModel(body: nil, activation: nil, defaults: defaults)
        #expect(reloaded.iconMode == .text)
    }
}
