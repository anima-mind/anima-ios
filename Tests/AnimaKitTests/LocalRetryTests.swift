import Foundation
import GRDB
import Testing
@testable import AnimaKit

// Con el modelo local, un error de parámetros vuelve con el error accionable +
// el ejemplo literal UNA vez; si vuelve a fallar (o falla el mundo: permiso,
// store), el turno cierra con el aviso "⚠️ No pude …" sin otra llamada al modelo.

extension LocalLoopHarness.Run {
    var notice: String? {
        events.compactMap { if case .toolFailure(let n) = $0 { return n } else { return nil } }.first
    }
}

@Suite struct LocalRetryTests {
    @Test func theLocalModelGetsOneGuidedRetryThenTheTurnCloses() async throws {
        let w = try ProactiveFixtures.world()
        let model = OnDeviceProvider.modelName
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "remind_me", #"{"text":"llamar al banco","when":"pronto","repeat":"none"}"#, model: model),
            LocalLoopHarness.toolUse("b", "remind_me", #"{"text":"llamar al banco","when":"luego","repeat":"none"}"#, model: model),
            LocalLoopHarness.text("Listo, quedó programado."),
        ], tools: [AnimaRemindersTool(store: w.reminders)], router: try OnDeviceTestConfig.router(),
           text: "recuérdame llamar al banco")
        // El aviso nunca muestra el texto interno del adapter.
        let notice = "⚠️ No pude crear el recordatorio: no entendí la fecha y la hora."
        #expect(r.notice == notice)
        #expect(r.text == notice)
        #expect(try r.lastAssistantText() == notice)
        #expect(r.events.contains(.turnFinished(stopReason: .endTurn)))
        #expect(r.events.filter { $0 == .toolFinished(name: "anima_reminders", isError: true) }.count == 2)
        // El primer error volvió al modelo con el ejemplo literal.
        let window = try r.store.window(sessionId: r.sid)
        let results = window.flatMap(\.content).compactMap { block -> String? in
            if case .toolResult(_, let content, true) = block { return content } else { return nil }
        }
        #expect(results.first?.hasSuffix("Ej: {text:'tomar la pastilla', when:'2026-10-07 08:00', repeat:'none'}") == true)
        #expect(await w.reminders.list().isEmpty)
    }

    @Test func theLoopRetriesTowardsTheIntendedTool() async throws {
        let w = try ProactiveFixtures.world()
        let model = OnDeviceProvider.modelName
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "list_reminders", "{}", model: model),
            LocalLoopHarness.toolUse("b", "remind_me", #"{"text":"llamar al banco","when":"2030-01-02 09:00","repeat":"none"}"#,
                                           model: model),
            LocalLoopHarness.text("Listo, te recuerdo llamar al banco."),
        ], tools: [AnimaRemindersTool(store: w.reminders)], router: try OnDeviceTestConfig.router(),
           policy: .app(ownerAllowlist: { [] }), text: "recuérdame el 2 de enero a las 9 llamar al banco")
        #expect(r.notice == nil)
        #expect(await w.reminders.list().count == 1)
        let window = try r.store.window(sessionId: r.sid)
        let firstError = window.flatMap(\.content).compactMap { block -> String? in
            if case .toolResult(_, let content, true) = block { return content } else { return nil }
        }.first
        #expect(firstError?.contains("Corrige y llama remind_me otra vez. Ej: {text:") == true)
    }

    @Test func localToolsNameTheirIntent() {
        #expect(LocalToolAdapter.verb(local: "remind_me") == "crear el recordatorio")
        #expect(LocalToolAdapter.verb(local: "declare_goal") == "registrar la meta")
        #expect(LocalToolAdapter.verb(local: "add_calendar_event") == "crear el evento")
        #expect(LocalToolAdapter.verb(local: "write_note") == "guardar la nota")
        #expect(LocalToolAdapter.verb(local: "read_note") == "leer la nota")
        #expect(LocalToolAdapter.verb(local: "list_reminders") == "consultar tus recordatorios")
        #expect(LocalToolAdapter.verb(local: "list_goals") == "consultar tus metas")
        #expect(LocalToolAdapter.verb(local: "list_events") == "consultar tu agenda")
        #expect(LocalToolAdapter.verb(local: "x") == "usar x")
    }

    @Test func legibleAndAdmissions() {
        #expect(ToolFailureNotice.legible("Error: falta 'id'.") == "falta 'id'")
        #expect(ToolFailureNotice.legible("Error: SQLite error 1: no such table: x - while executing `INSERT …`")
                == "SQLite error 1: no such table: x")
        #expect(ToolFailureNotice.legible("Falta `when`. Corrige y llama remind_me otra vez. Ej: {}") == "Falta `when`")
        #expect(ToolFailureNotice.legible("") == "la herramienta falló")
        #expect(ToolFailureNotice.legible("Acción cancelada: el dueño no la confirmó.") == "no lo confirmaste")
        #expect(ToolFailureNotice.legible(String(repeating: "a", count: 300)).count == 118)
        for text in ["No pude crearlo", "Falló el guardado", "hubo un ERROR", "No se pudo", "no logré hacerlo"] {
            #expect(ToolFailureNotice.admits(text), "\(text)")
        }
        #expect(!ToolFailureNotice.admits("Listo, quedó programado."))
        #expect(ToolFailureNotice.notice(failures: [], finalText: "x") == nil)
        #expect(ToolFailureNotice.prepend("N", to: []) == [.text("N")])
        #expect(ToolFailureNotice.prepend("N", to: [.thinking("t"), .text("  ")]) == [.thinking("t"), .text("N")])
    }

    @Test(arguments: [
        ("anima_reminders", "create", "crear el recordatorio"), ("anima_reminders", "list", "consultar tus recordatorios"),
        ("anima_reminders", "complete", "marcar el recordatorio como hecho"),
        ("anima_reminders", "cancel", "cancelar el recordatorio"), ("anima_reminders", "snooze", "posponer el recordatorio"),
        ("goals", "declare", "registrar la meta"), ("goals", "set_checkin", "registrar la meta"),
        ("goals", "list", "consultar tus metas"), ("goals", "record_checkin", "anotar el seguimiento"),
        ("goals", "mark_achieved", "marcar la meta como lograda"),
        ("calendar", "create", "crear el evento"), ("calendar", "list", "consultar tu agenda"),
        ("calendar", "search", "consultar tu agenda"), ("calendar", "delete", "borrar el evento"),
        ("notes", "create", "guardar la nota"), ("notes", "append", "guardar la nota"), ("notes", "read", "leer la nota"),
        ("notes", "list", "consultar tus notas"), ("reminders", "create", "crear el recordatorio en la app Recordatorios"),
        ("reminders", "list", "consultar la app Recordatorios"),
        ("reminders", "complete", "completar el recordatorio del iPhone"),
        ("camera", "capture", "completar la acción (Cámara)"),
    ])
    func verbs(tool: String, action: String, verb: String) {
        let actual = ToolFailureNotice.verb(tool: tool, input: .object(["action": .string(action)]))
        if tool == "camera" { #expect(actual.hasPrefix("completar la acción (")) } else { #expect(actual == verb) }
    }

}

@Suite struct LocalRedirectBudgetTests {
    /// La redirección no gasta el reintento: tras ella, un error de
    /// parámetros aún tiene su reintento guiado.
    @Test func aRedirectDoesNotSpendTheGuidedRetry() async throws {
        let w = try ProactiveFixtures.world()
        let model = OnDeviceProvider.modelName
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "list_reminders", "{}", model: model),
            LocalLoopHarness.toolUse("b", "remind_me", #"{"text":"x","when":"pronto","repeat":"none"}"#, model: model),
            LocalLoopHarness.toolUse("c", "remind_me", #"{"text":"x","when":"2030-01-02 09:00","repeat":"none"}"#, model: model),
            LocalLoopHarness.text("Listo, te recuerdo x."),
        ], tools: [AnimaRemindersTool(store: w.reminders)], router: try OnDeviceTestConfig.router(),
           policy: .app(ownerAllowlist: { [] }), text: "recuérdame el 2 de enero a las 9 x")
        #expect(r.notice == nil)
        #expect(await w.reminders.list().count == 1)
    }
}

@Suite struct LocalWorldFailureTests {
    /// Un fallo del mundo (store roto, sin permiso) no se reintenta ni lleva el
    /// ejemplo: el turno cierra con el aviso tras UNA llamada.
    @Test func aStoreFailureClosesTheTurnWithoutRetrying() async throws {
        let w = try ProactiveFixtures.world()
        try await w.queue.write { try $0.execute(sql: "DROP TABLE anima_reminder") }
        let model = OnDeviceProvider.modelName
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "remind_me", #"{"text":"x","when":"2030-01-02 09:00","repeat":"none"}"#, model: model),
            LocalLoopHarness.text("Listo, te recuerdo x."),
        ], tools: [AnimaRemindersTool(store: w.reminders)], router: try OnDeviceTestConfig.router(),
           policy: .app(ownerAllowlist: { [] }), text: "recuérdame el 2 de enero a las 9 x")
        #expect(r.notice?.hasPrefix("⚠️ No pude crear el recordatorio: SQLite error") == true)
        #expect(r.text == r.notice)
        let window = try r.store.window(sessionId: r.sid)
        let errors = window.flatMap(\.content).compactMap { block -> String? in
            if case .toolResult(_, let content, true) = block { return content } else { return nil }
        }
        #expect(errors.count == 1 && !(errors.first ?? "").contains("Corrige y llama"))
    }
}
