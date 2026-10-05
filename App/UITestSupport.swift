// UITestSupport.swift — modo UI-test del shell (XCUITest, App/UITests). Solo se
// activa con el launch argument `--uitest`; sin él, NADA de este archivo se usa
// y el binario se comporta exactamente igual. Dobles deterministas y sin red:
// config bundled (sin Firebase), cuenta mock, modelo local forzado a disponible
// con un provider que streamea una respuesta fija, y estado aislado (defaults,
// Keychain y base de datos propios) que `--uitest-reset` borra al arrancar.

import Foundation
import AnimaKit
#if canImport(UIKit)
import UIKit
#endif

enum UITestMode {
    static let flag = "--uitest"
    static let resetFlag = "--uitest-reset"

    static let isActive = ProcessInfo.processInfo.arguments.contains(flag)
    static let shouldReset = isActive && ProcessInfo.processInfo.arguments.contains(resetFlag)

    static let suiteName = "com.joshuamoreno1.anima.uitest"
    static let keychainService = "dev.joshua.anima.provider-token.uitest"
    static let databaseName = "anima-uitest.sqlite"

    /// Suite efímera: jamás toca `UserDefaults.standard` del dueño.
    static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    /// Borra flags de onboarding/modo, token y base de datos del modo UI-test.
    static func resetIfRequested() {
        guard shouldReset else { return }
        defaults.removePersistentDomain(forName: suiteName)
        try? KeychainStore(service: keychainService).delete()
        let tokens = ProviderTokenStore(service: keychainService)
        for provider in ModelProvider.remoteCases { try? tokens.delete(provider) }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(databaseName + suffix))
        }
    }

    /// Config congelada desde los defaults bundled (RemoteConfigDefaults.plist), sin fetch.
    static func bundledConfig() -> StaticConfigProvider {
        var values: [String: Any] = [:]
        if let url = Bundle.main.url(forResource: "RemoteConfigDefaults", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            values = plist
        }
        let snapshot = FirebaseConfigProvider.buildSnapshot { key in
            (values[key] as? String)?.data(using: .utf8) ?? Data()
        } stringLookup: { key in
            values[key] as? String ?? ""
        }
        return StaticConfigProvider(snapshot)
    }

    /// Foto fixture del picker guionado (JPEG 800×600 de color plano).
    static func fixturePhoto() -> Data? {
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600))
        return renderer.jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor(red: 0.58, green: 0.74, blue: 0.89, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        #else
        return nil
        #endif
    }

    /// El modelo local se reporta disponible (el provider guionado lo reemplaza).
    static let forcedAvailability: OnDeviceAvailability = .available
}

/// Provider guionado del modo UI-test (reemplaza a Claude y al modelo local).
/// - Turno normal: streamea `fixedReply` por trozos (ventana visible del caret).
/// - Si el dueño menciona "calendario": pide la tool `calendar` (list) para
///   ejercitar el TCC real de EventKit, y al volver el tool_result responde
///   "Calendario concedido …" o "Calendario sin permiso …" (fail-closed).
struct UITestScriptedProvider: Provider {
    static let fixedReply = "Hola, soy Anima en modo de prueba. Te escucho."
    static let thought = "Saludo breve. Respondo en modo de prueba."
    /// ~3 s de stream (5 trozos): ventana holgada para que el test vea el caret.
    static let chunkDelay: Duration = .milliseconds(600)

    enum Plan: Equatable {
        case text(String)
        case calendarTool
    }

    static func plan(for ctx: AssembledContext) -> Plan {
        guard let last = ctx.messages.last(where: { $0.role == .user }) else { return .text(fixedReply) }
        for block in last.content {
            if case .toolResult(_, let content, let isError) = block {
                return .text(isError ? "Calendario sin permiso: \(content)" : "Calendario concedido: \(content)")
            }
        }
        let text = last.content.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined(separator: " ")
        return text.lowercased().contains("calendario") ? .calendarTool : .text(fixedReply)
    }

    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let plan = Self.plan(for: ctx)
        let model = opts.route.model
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.messageStart(id: "uitest-\(UUID().uuidString)", model: model))
                switch plan {
                case .text(let reply):
                    // Resumen de razonamiento: la thought line queda en pantalla
                    // (expandible) para ejercitar su tap con el teclado abierto.
                    continuation.yield(.thinkingDelta(Self.thought))
                    for chunk in Self.chunks(reply) {
                        try? await Task.sleep(for: Self.chunkDelay)
                        if Task.isCancelled { break }
                        continuation.yield(.textDelta(chunk))
                    }
                    continuation.yield(.blockStop(index: 0))
                    continuation.yield(.messageDelta(stopReason: .endTurn,
                                                     usage: Usage(inputTokens: 10, outputTokens: 10)))
                case .calendarTool:
                    continuation.yield(.toolUseStart(id: "uitest-cal-\(UUID().uuidString)", name: "calendar"))
                    continuation.yield(.toolUseInputDelta(#"{"action":"list","days_ahead":7}"#))
                    continuation.yield(.blockStop(index: 0))
                    continuation.yield(.messageDelta(stopReason: .toolUse,
                                                     usage: Usage(inputTokens: 10, outputTokens: 5)))
                }
                continuation.yield(.messageStop)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Trozos de ~2 palabras.
    static func chunks(_ text: String) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var index = 0
        while index < words.count {
            let slice = words[index..<min(index + 2, words.count)].joined(separator: " ")
            out.append(index + 2 < words.count ? slice + " " : slice)
            index += 2
        }
        return out
    }
}

/// Voz guionada del modo UI-test (mic del composer): emite un parcial en vivo y
/// devuelve un transcript fijo al terminar (≈1.5 s o "Listo"); cancel → nil.
final class UITestScriptedVoice: VoiceCapturePort, @unchecked Sendable {
    static let transcript = "hola por voz"
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void) async -> String? {
        await capture(onRoute: onRoute, onPartial: { _ in })
    }

    func capture(onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                 onPartial: @escaping @Sendable (String) -> Void) async -> String? {
        set(cancelled: false, finished: false)
        onRoute(.phoneMic)
        try? await Task.sleep(for: .milliseconds(300))
        onPartial("hola por")
        for _ in 0..<12 where !state().finished && !state().cancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return state().cancelled ? nil : Self.transcript
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func finish() { lock.lock(); finished = true; lock.unlock() }

    private func set(cancelled: Bool, finished: Bool) {
        lock.lock(); self.cancelled = cancelled; self.finished = finished; lock.unlock()
    }
    private func state() -> (cancelled: Bool, finished: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (cancelled, finished)
    }
}
