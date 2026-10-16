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

    static let seedGoalFlag = "--uitest-seed-goal"
    static let seededGoalStatement = "Ahorrar 10 millones para invertir"
    /// Meta INFERIDA pendiente de confirmar: una aprobación en Ajustes → Mente.
    static let seedInferredGoalFlag = "--uitest-seed-inferred-goal"
    static let seededInferredStatement = "Dormir 7 horas"

    /// Recordatorio sembrado a +N s con notificaciones REALES (XCUITest del tap al push).
    static let seedReminderPrefix = "--uitest-seed-reminder="
    static let seededReminderText = "Cita médica de prueba"
    static let seededReminderMessage = "Oye, ya casi es tu cita médica de prueba."
    /// Persiste el modo UI-test (solo DEBUG + simulador) para que un lanzamiento
    /// del sistema —tap a la notificación con la app terminada— siga aislado.
    static let stickyFlag = "--uitest-sticky"

    /// Aviso por inactividad adelantado: el "Probar" de Ajustes a +N s (XCUITest del tap).
    static let nudgeProbePrefix = "--uitest-nudge-probe="
    /// Una pregunta del sueño ya guardada (la que el aviso debe llevar).
    static let seedNudgeQuestionFlag = "--uitest-seed-nudge-question"
    static let seededNudgeQuestion = "¿Cómo te fue en la reunión con Pedro?"

    static let arguments: [String] = resolveArguments()
    static let isActive = arguments.contains(flag)
    static let seedsGoal = isActive && arguments.contains(seedGoalFlag)
    static let seedsInferredGoal = isActive && arguments.contains(seedInferredGoalFlag)
    /// Una memoria activa de la "noche 1" para el XCUITest de Memoria.
    static let seedsMemory = isActive && arguments.contains("--uitest-seed-memory")
    static let seededMemory = "Le gusta correr temprano"

    static func seedMemory(_ brain: Brain) async {
        guard ((try? await brain.browse()) ?? []).isEmpty else { return }
        _ = try? await brain.add(MemoryCandidate(content: seededMemory, source: "cycle:1"), cycle: 1)
    }

    /// Galería de widgets (screenshots de cada widget con datos de ejemplo).
    static let showsWidgetGallery = isActive && (arguments.contains("--uitest-widget-gallery") || widgetOnly != nil)
    /// `--uitest-widget=<id>`: la galería pinta SOLO ese widget, centrado (screenshot entero).
    static let widgetOnly: String? = isActive
        ? arguments.lazy.compactMap { arg -> String? in
            arg.hasPrefix("--uitest-widget=") ? String(arg.dropFirst("--uitest-widget=".count)) : nil
        }.first
        : nil

    /// Una propuesta del deseo pendiente en el chat (batch 8 #1: una sola card).
    static let seedsIntention = isActive && arguments.contains("--uitest-seed-intention")
    static let seededProposal = "¿El miércoles a las 8:00 hacemos tu primer check-in?"

    /// Idempotente entre relanzamientos: solo si aún no hay Intentions.
    static func seedIntention(_ engine: DesireEngine, _ otherModel: OtherModel, sessionId: SessionID) async {
        guard await engine.allIntentions().isEmpty else { return }
        let id = await otherModel.ingestStated(statement: "Bajar 10 kg", desiredState: .progressCheckIn(everyDays: 7),
                                               evidence: "uitest")
        guard let goal = await otherModel.goal(id: id) else { return }
        await engine.recordProposal(goal: goal, text: seededProposal, sessionId: sessionId)
    }

    /// Un turno de voz hecho desde las gafas (+ la respuesta), como lo persiste el loop (batch 8 #2).
    static let seedsGlassesTurn = isActive && arguments.contains("--uitest-seed-glasses-turn")
    static let seededGlassesTranscript = "¿qué tengo mañana?"

    static func seedGlassesTurn(_ store: SymbolicStore, sessionId: SessionID) {
        let turns = (try? store.historyPage().turns) ?? []
        guard !turns.contains(where: { $0.surface == .glassesHUD }) else { return }
        try? store.append(sessionId: sessionId, message: .user([AudioTool.transcriptBlock(seededGlassesTranscript)]),
                          surface: .glassesHUD)
        try? store.append(sessionId: sessionId, message: .assistant([.text("Mañana tienes el standup a las 9.")]),
                          surface: .glassesHUD)
    }

    /// 60 turnos previos: el chat debe abrir anclado al último (review #34).
    static let seedsLongHistory = isActive && arguments.contains("--uitest-seed-long-history")

    static func seedLongHistory(_ store: SymbolicStore, sessionId: SessionID) {
        guard ((try? store.historyPage().turns) ?? []).isEmpty else { return }
        for i in 0..<30 {
            try? store.append(sessionId: sessionId, message: .user("mensaje \(i)"))
            try? store.append(sessionId: sessionId, message: .assistant([.text("respuesta \(i)\nCon una segunda línea para que ocupe.")]))
        }
    }

    /// Un turno de CarPlay sin la pantalla del carro (la conversación con voz
    /// guionada): queda en el chat con el chip "CarPlay".
    static let runsCarPlayTurn = isActive && arguments.contains("--uitest-carplay-turn")

    /// Simula >8 h sin actividad: el lanzamiento abre sesión nueva (historial completo, batch 8 #3).
    static let forcesFreshSession = isActive && arguments.contains("--uitest-fresh-session")

    /// Sin red forzado (pill "Sin conexión" + turno encolado).
    static let forcesOffline = isActive && arguments.contains("--uitest-offline")
    static let shouldReset = isActive && arguments.contains(resetFlag)
    static let seedReminderSeconds: Int? = isActive
        ? arguments.lazy.compactMap { arg -> Int? in
            guard arg.hasPrefix(seedReminderPrefix) else { return nil }
            return Int(arg.dropFirst(seedReminderPrefix.count))
        }.first
        : nil
    static let nudgeProbeSeconds: Int? = isActive
        ? arguments.lazy.compactMap { arg -> Int? in
            guard arg.hasPrefix(nudgeProbePrefix) else { return nil }
            return Int(arg.dropFirst(nudgeProbePrefix.count))
        }.first
        : nil
    static let seedsNudgeQuestion = isActive && arguments.contains(seedNudgeQuestionFlag)

    /// Idempotente: solo si la base aún no tiene preguntas.
    static func seedNudgeQuestion(_ store: ReengagementQuestionStore) {
        guard store.upcoming(limit: 1).isEmpty else { return }
        _ = try? store.replace(with: [seededNudgeQuestion], cycle: 1)
    }

    /// UNUserNotificationCenter real (y no el doble denegado) en modo UI-test.
    static let usesRealNotifications = isActive && arguments.contains(stickyFlag)

    private static var stickyURL: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("uitest-sticky.plist")
    }

    private static func resolveArguments() -> [String] {
        let launched = ProcessInfo.processInfo.arguments
        #if DEBUG && targetEnvironment(simulator)
        if launched.contains(flag) {
            if launched.contains(stickyFlag) {
                let kept = launched.filter {
                    $0 != resetFlag && !$0.hasPrefix(seedReminderPrefix) && !$0.hasPrefix(nudgeProbePrefix)
                }
                (kept as NSArray).write(to: stickyURL, atomically: true)
            } else {
                try? FileManager.default.removeItem(at: stickyURL)
            }
            return launched
        }
        if let stored = NSArray(contentsOf: stickyURL) as? [String] { return stored }
        #endif
        return launched
    }

    static let suiteName = "com.joshuamoreno1.anima.uitest"
    static let keychainService = "dev.joshua.anima.provider-token.uitest"
    static let databaseName = "anima-uitest.sqlite"
    static let skillsDirectoryName = "skills-uitest"

    /// Suite efímera: jamás toca `UserDefaults.standard` del dueño.
    static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    /// Borra flags de onboarding/modo, token, base de datos y skills del modo UI-test.
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
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(skillsDirectoryName, isDirectory: true))
    }

    /// Una meta declarada (idempotente por enunciado) para el XCUITest de Metas.
    static func seedGoal(_ otherModel: OtherModel) async {
        await otherModel.ingestStated(statement: seededGoalStatement,
                                      desiredState: .progressCheckIn(everyDays: 2), evidence: "uitest")
    }

    static func seedInferredGoal(_ otherModel: OtherModel) async {
        guard await otherModel.pendingConfirmations().isEmpty else { return }
        _ = await otherModel.infer(statement: seededInferredStatement,
                                   desiredState: .progressCheckIn(everyDays: 1), evidence: "uitest")
    }

    /// Recordatorio de prueba a +`seconds` (el XCUITest de notificación lo toca).
    static func seedReminder(_ store: AnimaReminderStore, seconds: Int) async {
        _ = try? await store.create(text: seededReminderText, message: seededReminderMessage, fireAt: Date().addingTimeInterval(TimeInterval(seconds)))
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
        /// Eferente que toca el mundo: dispara el sheet de confirmación.
        case calendarCreate
    }

    /// Taller de skills (FIX A): borrador fijo + la siguiente pregunta.
    static let skillReply = """
        <skill>
        ---
        name: regar-plantas
        description: Recuerda y guía el riego de las plantas de la casa
        when: regar las plantas, riego, plantas de la casa
        ---
        1. Pregunta qué plantas toca regar hoy.
        2. Recuerda que el helecho va cada dos días.
        </skill>
        ¿Algo más o lo cambio?
        """

    /// Markdown de bloques (encabezados, tabla, listas): el mensaje real del dueño.
    static let markdownReply = """
        ## 📅 Plan mensual de ahorro

        Para llegar a **10 millones** en un año:

        | Mes | Aporte | Acumulado |
        |-----|-------:|----------:|
        | Octubre | $850.000 | $850.000 |
        | Noviembre | $850.000 | $1.700.000 |
        | Diciembre | $1.000.000 | $2.700.000 |

        ### Para aterrizarlo…
        - Programa una **transferencia automática** el día 1.
        - Revisa gastos hormiga:
          - domicilios
          - suscripciones
        1. Abre el CDT en noviembre.
        2. Revisa el avance cada mes.

        > Lo que no se mide no se mejora.

        ---
        ¿Te lo dejo como recordatorio?
        """

    /// Respuesta larga (batch 10 #1): desborda la pantalla y llega en ráfagas de
    /// 3 párrafos (>80 pt por frame, como un stream real que se acumula entre
    /// frames): ejercita el auto-scroll y el "no me jales". Se PAUSA tras los
    /// párrafos de `longReplyPauses` hasta que el test la suelte
    /// (UITestStreamGate): sin depender del reloj en un runner lento.
    static let longReplyEnd = "Fin de la respuesta larga."
    static let longReply = (1...48).map { "Punto \($0): una línea con texto suficiente para ocupar espacio en la pantalla del chat." }
        .joined(separator: "\n\n") + "\n\n" + longReplyEnd
    static let longReplyDelay: Duration = .milliseconds(300)
    static let longReplyPauses = ["Punto 21:", "Punto 33:"]

    static func plan(for ctx: AssembledContext) -> Plan {
        let inWorkshop = ctx.messages.contains { message in
            message.role == .system && message.content.contains { block in
                if case .text(let t) = block { return t.contains(SkillWorkshopSession.marker) }
                return false
            }
        }
        if inWorkshop { return .text(skillReply) }
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
        if text.lowercased().contains("markdown") { return .text(markdownReply) }
        if text.lowercased().contains("respuesta larga") { return .text(longReply) }
        if text.lowercased().contains("agéndame") { return .calendarCreate }
        return text.lowercased().contains("calendario") ? .calendarTool : .text(fixedReply)
    }

    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let plan = Self.plan(for: ctx)
        let model = opts.route.model
        // Con el modelo local el set es el del LocalToolAdapter.
        let local = OnDeviceProvider.isOnDevice(model: model)
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.messageStart(id: "uitest-\(UUID().uuidString)", model: model))
                switch plan {
                case .text(let reply):
                    // Resumen de razonamiento: la thought line queda en pantalla
                    // (expandible) para ejercitar su tap con el teclado abierto.
                    continuation.yield(.thinkingDelta(Self.thought))
                    let delay: Duration = reply == Self.longReply ? Self.longReplyDelay
                        : reply == Self.skillReply || reply == Self.markdownReply ? .milliseconds(40) : Self.chunkDelay
                    let gate = UITestStreamGate.passes
                    var paused = 0
                    for chunk in reply == Self.longReply ? Self.bursts(reply) : Self.chunks(reply) {
                        try? await Task.sleep(for: delay)
                        if Task.isCancelled { break }
                        continuation.yield(.textDelta(chunk))
                        if reply == Self.longReply, Self.longReplyPauses.contains(where: chunk.contains) {
                            paused += 1
                            await UITestStreamGate.wait(until: gate + paused)
                        }
                    }
                    continuation.yield(.blockStop(index: 0))
                    continuation.yield(.messageDelta(stopReason: .endTurn,
                                                     usage: Usage(inputTokens: 10, outputTokens: 10)))
                case .calendarCreate:
                    continuation.yield(.toolUseStart(id: "uitest-cal-\(UUID().uuidString)",
                                                     name: local ? "add_calendar_event" : "calendar"))
                    continuation.yield(.toolUseInputDelta(local
                        ? #"{"title":"Reunión con Pedro","start":"2026-10-08 15:00","end":"2026-10-08 16:00"}"#
                        : #"{"action":"create","title":"Reunión con Pedro","start":"2026-10-08T15:00:00-05:00","end":"2026-10-08T16:00:00-05:00"}"#))
                    continuation.yield(.blockStop(index: 0))
                    continuation.yield(.messageDelta(stopReason: .toolUse,
                                                     usage: Usage(inputTokens: 10, outputTokens: 5)))
                case .calendarTool:
                    continuation.yield(.toolUseStart(id: "uitest-cal-\(UUID().uuidString)",
                                                     name: local ? "list_events" : "calendar"))
                    continuation.yield(.toolUseInputDelta(local ? #"{"days":7}"# : #"{"action":"list","days_ahead":7}"#))
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

    /// Ráfagas de 3 párrafos.
    static func bursts(_ text: String) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        return stride(from: 0, to: paragraphs.count, by: 3).map { start in
            let end = min(start + 3, paragraphs.count)
            return paragraphs[start..<end].joined(separator: "\n\n") + (end < paragraphs.count ? "\n\n" : "")
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

/// Compuerta del stream largo: el XCUITest la suelta con una notificación
/// Darwin (cruza del runner a la app en el simulador, sin permisos ni red).
/// Tope de seguridad: 120 s por pausa.
enum UITestStreamGate {
    static let name = "com.joshuamoreno1.anima.uitest.stream.resume"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var installed = false

    static var passes: Int {
        install()
        return lock.withLock { count }
    }

    static func install() {
        let first = lock.withLock { () -> Bool in
            defer { installed = true }
            return !installed
        }
        guard first else { return }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            UITestStreamGate.lock.withLock { UITestStreamGate.count += 1 }
        }, name as CFString, nil, .deliverImmediately)
    }

    static func wait(until target: Int) async {
        for _ in 0..<1200 where lock.withLock({ count }) < target {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Voz guionada del modo UI-test (mic del composer): emite un parcial en vivo y
/// devuelve un transcript fijo al terminar (≈1.5 s o "Listo"); cancel → nil.
final class UITestScriptedVoice: VoiceCapturePort, @unchecked Sendable {
    static let transcript = "hola por voz"
    static let timeScale: Double = max(1, ProcessInfo.processInfo.environment["UITEST_TIMEOUT_SCALE"]
        .flatMap(Double.init) ?? 1)
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
        // Ventana de escucha × UITEST_TIMEOUT_SCALE: en runners lentos la barra
        // debe vivir lo suficiente para que el test la observe.
        let ticks = Int(12 * Self.timeScale)
        for _ in 0..<ticks where !state().finished && !state().cancelled {
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
