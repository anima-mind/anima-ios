import Foundation
import Testing
@testable import AnimaKit

// Campo batch 8 #6: aceptó "¿el miércoles a las 8:00 hacemos tu primer
// check-in?" y respondió "Listo, te programo el check-in… Quedó agendado" SIN
// tool: ni recordatorio ni seguimiento. Mentira sin tool, en cualquier proveedor.

@Suite("Batch 8 #6 — afirmar una escritura exige haberla hecho")
struct ActionClaimGuardTests {

    @Test func detectaLasAfirmacionesDeEscritura() {
        for text in ["Listo, te programo el check-in para mañana miércoles a las 8:00.",
                     "Quedó agendado.", "Agendé tu cita.", "Te programé el recordatorio.",
                     "Registré tu meta de bajar 10 kg.", "Creé el recordatorio.", "Te lo recuerdo a las 7.",
                     "Te voy a recordar el miércoles.", "Listo, quedó.", "Ya está programado para las 8."] {
            #expect(ActionClaimGuard.claimsWrite(text), "\(text)")
        }
        for text in ["¿Lo agendamos para el miércoles?", "No lo agendé todavía.", "Aún no programé nada.",
                     "Ese recordatorio ya existía desde ayer.", "¿Cómo te quedó el entrenamiento?",
                     "Tienes 2 recordatorios.", "Sin programar nada aún.",
                     "Eso no lo puedo cambiar desde aquí. Programados: - llamar al banco"] {
            #expect(!ActionClaimGuard.claimsWrite(text), "\(text)")
        }
    }

    @Test func soloLasEscriturasCuentan() {
        #expect(ActionClaimGuard.isWrite(tool: "goals", input: .object(["action": .string("set_checkin")])))
        #expect(ActionClaimGuard.isWrite(tool: "anima_reminders", input: .object(["action": .string("create")])))
        #expect(!ActionClaimGuard.isWrite(tool: "anima_reminders", input: .object(["action": .string("list")])))
        #expect(!ActionClaimGuard.isWrite(tool: "calendar", input: .object(["action": .string("search")])))
        #expect(!ActionClaimGuard.isWrite(tool: "glasses_camera", input: .object([:])))
        #expect(ActionClaimGuard.canWrite([AnimaRemindersTool(store: AnimaReminderStore(
            queue: try! AnimaDatabase.temporary())).spec]))
        #expect(!ActionClaimGuard.canWrite([]))
        #expect(ToolFailureNotice.isNotice(ActionClaimGuard.notice))
        #expect(ToolFailureNotice.isNotice("⚠️ No pude crear el recordatorio: x."))
        #expect(!ToolFailureNotice.isNotice("Listo."))
    }

    /// Provider que miente dos veces: reintento + la línea fija al frente.
    @Test func mentirDosVecesAntepneLaLinea() async throws {
        let w = try ProactiveFixtures.world()
        let lie = "Listo, te programo el check-in para mañana miércoles a las 8:00. Quedó agendado."
        let r = try await LocalLoopHarness.run([LocalLoopHarness.text(lie), LocalLoopHarness.text(lie)],
                                               tools: [AnimaRemindersTool(store: w.reminders)],
                                               policy: .app(ownerAllowlist: { [] }))
        #expect(r.events.contains(.retracted))
        #expect(r.events.contains(.toolFailure(ActionClaimGuard.notice)))
        #expect(try r.lastAssistantText() == ActionClaimGuard.notice + "\n\n" + lie)
        #expect(await w.reminders.list().isEmpty)
        // El reintento no queda en el transcript: una sola respuesta del asistente.
        let visible = try r.store.visibleTurns(sessionId: r.sid)
        #expect(visible.map(\.role) == [.user, .assistant])
        #expect(!visible.contains { $0.text.contains(ActionClaimGuard.nudgeMarker) })
    }

    /// Miente, se le pide ejecutar, ejecuta: sin aviso, el recordatorio existe.
    @Test func elReintentoEjecutaLaTool() async throws {
        let w = try ProactiveFixtures.world()
        let capture = CapturingProvider([
            LocalLoopHarness.text("Quedó agendado tu check-in."),
            LocalLoopHarness.toolUse("a", "anima_reminders",
                #"{"action":"create","text":"primer check-in","message":"Oye, ¿cómo vas con tu meta?","fire_at":"2030-01-02T08:00:00-05:00"}"#),
            LocalLoopHarness.text("Listo, quedó agendado para el miércoles a las 8:00."),
        ])
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: capture, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-x", clientTools: [AnimaRemindersTool(store: w.reminders)],
                             serverTools: [], permissionPolicy: .app(ownerAllowlist: { [] }), sleep: { _ in })
        let sid = try store.startSession()
        var events: [LoopEvent] = []
        for await e in await loop.run(sessionId: sid, userText: "sí, hagámoslo") { events.append(e) }
        #expect(events.contains(.retracted))
        #expect(!events.contains { if case .toolFailure = $0 { true } else { false } })
        #expect(await w.reminders.list().count == 1)
        // La 2.ª llamada lleva la verificación del harness como último turno del dueño.
        let second = try #require(capture.captures.value.dropFirst().first?.messages.last)
        #expect(second == .user(ActionClaimGuard.nudge))
        let visible = try store.visibleTurns(sessionId: sid)
        #expect(visible.last?.text == "Listo, quedó agendado para el miércoles a las 8:00.")
        #expect(!visible.contains { $0.text == "Quedó agendado tu check-in." })
    }

    @Test func conEscrituraExitosaNoHayReintento() async throws {
        let w = try ProactiveFixtures.world()
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "anima_reminders",
                #"{"action":"create","text":"x","message":"Oye, x.","fire_at":"2030-01-02T08:00:00-05:00"}"#),
            LocalLoopHarness.text("Listo, quedó agendado."),
        ], tools: [AnimaRemindersTool(store: w.reminders)], policy: .app(ownerAllowlist: { [] }))
        #expect(!r.events.contains(.retracted))
        #expect(try r.lastAssistantText() == "Listo, quedó agendado.")
    }

    /// Medido con el modelo local: tras list_reminders citaba "Programados: …"
    /// y el guard lo tomaba por afirmación. Una consulta exitosa describe lo existente.
    @Test func trasUnaConsultaElListadoNoEsAfirmacion() async throws {
        let w = try ProactiveFixtures.world()
        _ = try await w.reminders.create(text: "llamar al banco", fireAt: Date().addingTimeInterval(86_400))
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "anima_reminders", #"{"action":"list"}"#),
            LocalLoopHarness.text("Tienes esto programado: llamar al banco mañana."),
        ], tools: [AnimaRemindersTool(store: w.reminders)], policy: .app(ownerAllowlist: { [] }))
        #expect(!r.events.contains(.retracted))
    }

    @Test func sinToolsDeEscrituraNoSeVigila() async throws {
        let r = try await LocalLoopHarness.run([LocalLoopHarness.text("Quedó agendado.")], tools: [])
        #expect(!r.events.contains(.retracted))
        #expect(try r.lastAssistantText() == "Quedó agendado.")
    }

    @Test func laAceptacionSePintaComoHagamoslo() throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let inbox = ConsolidationInbox(queue: queue)
        let sid = try store.startSession()
        try store.append(sessionId: sid, message: .user(IntentionAcceptance.prompt(proposal: "¿check-in?", goalId: "g")))
        try store.append(sessionId: sid, message: .user(ActionClaimGuard.nudge))
        #expect(try store.visibleTurns(sessionId: sid).map(\.text) == [IntentionAcceptance.shownText])
        _ = inbox
    }
}

@Suite("Batch 8 #6 — Hagámoslo no entra al sueño como dicho del dueño")
struct AcceptanceInboxTests {
    @Test func laInstruccionNoSeEncola() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let inbox = ConsolidationInbox(queue: queue)
        let loop = AgentLoop(provider: ScriptedProvider([LocalLoopHarness.text("ok")]), store: store,
                             telemetry: Telemetry(queue: queue), router: ModelRouter(config: try TestConfig.providerConfig()),
                             authMode: .apiKey, token: "sk-ant-api03-x", clientTools: [], serverTools: [],
                             inbox: inbox, sleep: { _ in })
        let sid = try store.startSession()
        for await _ in await loop.run(sessionId: sid, userText: IntentionAcceptance.prompt(proposal: "p", goalId: nil)) {}
        let pending = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM consolidation_inbox") }
        #expect(pending == 0)
    }
}
