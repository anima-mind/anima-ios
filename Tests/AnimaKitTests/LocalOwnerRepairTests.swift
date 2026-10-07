import Foundation
import Testing
@testable import AnimaKit

/// Lo que el dueño dijo repara al 3B, pero sin repararlo de más.
@Suite struct LocalOwnerRepairTests {
    static func real(_ name: String, _ input: [String: JSONValue], owner: String) -> JSONValue? {
        let r = LocalToolAdapter.resolve(name: name, input: .object(input), now: LocalToolAdapterTests.now,
                                         ownerText: owner, calendar: LocalToolAdapterTests.calendar)
        if case .real(_, let real) = r { return real }
        return nil
    }

    static func remind(_ owner: String, when: String, repeat cadence: String = "none") -> JSONValue? {
        real("remind_me", ["text": .string("x"), "when": .string(when), "repeat": .string(cadence)], owner: owner)
    }

    @Test(arguments: [
        // Fecha explícita: el día de la semana no la pisa (modelo correcto).
        ("recuérdame el jueves 15 de octubre a las 10 la cita", "2026-10-15 10:00", "2026-10-15T10:00:00"),
        ("recuérdame el 15 de noviembre a las 9 pagar el arriendo", "2026-11-15 09:00", "2026-11-15T09:00:00"),
        ("recuérdame el 3 de enero a las 9 renovar", "2026-01-03 09:00", "2027-01-03T09:00:00"),
        ("recuérdame el 20/10 a las 8 pm el partido", "2026-10-21 08:00", "2026-10-20T20:00:00"),
        // "hoy" explícito gana; lo dictado tras "que" no fija el día.
        ("recuérdame hoy a las 6 de la tarde que mañana es el examen", "2026-10-07 18:00", "2026-10-06T18:00:00"),
        ("recuérdame que mañana a las 8 tengo examen", "2026-10-06 08:00", "2026-10-07T08:00:00"),
        ("recuérdame pasado mañana a las 10 llevar el carro", "2026-10-07 10:00", "2026-10-08T10:00:00"),
        ("recuérdame el viernes a las 7 de la noche sacar la basura", "2026-10-08 19:00", "2026-10-09T19:00:00"),
    ])
    func dayRepair(owner: String, model: String, expected: String) throws {
        #expect(try #require(Self.remind(owner, when: model))["fire_at"] == .string(expected))
    }

    @Test func inHoursAndMinutesIsRelativeToTheClock() throws {
        #expect(try #require(Self.remind("en 2 horas revisar el horno", when: "2026-10-06 11:00"))["fire_at"]
                == .string("2026-10-06T12:30:00"))
        #expect(try #require(Self.remind("recuérdame en 30 minutos sacar la ropa", when: "2026-10-06 10:00"))["fire_at"]
                == .string("2026-10-06T11:00:00"))
        #expect(try #require(Self.remind("en media hora", when: "2026-10-06 10:00"))["fire_at"]
                == .string("2026-10-06T11:00:00"))
    }

    @Test(arguments: [
        ("recuérdame todos los lunes a las 9 la reunión", "2026-10-07 09:00", "weekly", "weekly", "2026-10-12T09:00:00"),
        ("recuérdame los sábados a las 10 regar", "2026-10-07 10:00", "none", "weekly", "2026-10-10T10:00:00"),
        ("recuérdame todos los días laborales a las 8 tomar la pastilla", "2026-10-06 08:00", "none", "weekdays",
         "2026-10-07T08:00:00"),
        // Repetición que la app no hace: una vez, dentro de un periodo (nunca semanal inventado).
        ("recuérdame cada quince días a las 9 cortar el pelo", "2026-10-07 09:00", "weekly", "none", "2026-10-21T09:00:00"),
        ("recuérdame mañana a las 9 llamar al banco", "2026-10-07 09:00", "daily", "none", "2026-10-07T09:00:00"),
    ])
    func repetitionFromTheOwnerOrTheModel(owner: String, when: String, model: String, expected: String,
                                          fire: String) throws {
        let input = try #require(Self.remind(owner, when: when, repeat: model))
        #expect(input["repeat"] == .string(expected))
        #expect(input["fire_at"] == .string(fire))
    }

    @Test func eventRangeKeepsTheOwnersFirstAndLastHour() throws {
        let range = try #require(Self.real("add_calendar_event", [
            "title": .string("taller"), "start": .string("2026-10-08 09:00"), "end": .string("2026-10-08 11:00")],
            owner: "agéndame el taller el jueves de 9 am a 11 am"))
        #expect(range["start"] == .string("2026-10-08T09:00:00"))
        #expect(range["end"] == .string("2026-10-08T11:00:00"))
        let modelEnd = try #require(Self.real("add_calendar_event", [
            "title": .string("x"), "start": .string("2026-10-08 15:00"), "end": .string("2026-10-08 17:00")],
            owner: "agéndame reunión el jueves a las 3 pm"))
        #expect(modelEnd["end"] == .string("2026-10-08T17:00:00"))
    }

    @Test func weeklyGoalCheckInKeepsTheOwnersWeekday() throws {
        let goal = try #require(Self.real("declare_goal", [
            "statement": .string("leer 12 libros"), "checkin": .string("weekly"), "hour": .int(20)],
            owner: "quiero leer 12 libros este año, pregúntame cada domingo"))
        #expect(goal["checkin"] == .object(["cadence": .string("weekly"), "hour": .int(20), "weekday": .int(1)]))
    }

    @Test(arguments: [
        ("list_goals", "quiero ver mis metas"),
        ("list_reminders", "quiero saber qué recordatorios tengo"),
        ("list_reminders", "dime mis recordatorios"),
        ("list_goals", "cuáles son mis metas"),
    ])
    func aQueryIsNeverRedirected(called: String, owner: String) {
        #expect(LocalToolAdapter.intended(name: called, ownerText: owner) == called)
    }

    @Test func quieroIsAGoalOnlyWithAGoalVerb() {
        #expect(LocalToolAdapter.intended(name: "list_goals", ownerText: "quiero bajar 5 kilos") == "declare_goal")
        #expect(LocalToolAdapter.intended(name: "list_goals", ownerText: "quiero que me ayudes") == "list_goals")
        #expect(LocalToolAdapter.intended(name: "list_reminders", ownerText: "recuérdame revisar el horno") == "remind_me")
    }

    @Test func swappedNoteFieldsAreRepaired() throws {
        let note = try #require(Self.real("write_note", [
            "name": .string("la clave del wifi de la oficina es casa123"), "content": .string("wifi")],
            owner: "guarda que la clave del wifi de la oficina es casa123"))
        #expect(note["name"] == .string("wifi"))
        #expect(note["content"] == .string("la clave del wifi de la oficina es casa123"))
    }

    @Test func goalsAreListedReadably() {
        let raw = "- [G-1] leer 12 libros (stated, reportar avance cada 8 días); check-in cada domingo a las 20:00; racha 2 días"
        #expect(LocalToolAdapter.readableGoals(raw) == "- leer 12 libros — te pregunto cada domingo a las 20:00 — racha 2 días")
        #expect(LocalToolAdapter.readableGoals("El dueño no tiene metas activas.") == "No tienes metas activas.")
    }

    @Test func parameterErrorsAreTheOnlyRetryableOnes() {
        #expect(LocalToolAdapter.isParameterError("Error: la fecha ya pasó; usa una fecha futura."))
        #expect(LocalToolAdapter.isParameterError("Error: falta 'fire_at'."))
        #expect(!LocalToolAdapter.isParameterError("El dueño no ha concedido acceso al calendario."))
        #expect(!LocalToolAdapter.isParameterError("Error: SQLite error 1: no such table: anima_reminder"))
    }
}

@Suite struct LocalConfirmationHonestyTests {
    static let garbage: [SalientGroup] = [.subject(["saca", "basu"]), SalientGroup(OnDevicePromptBuilder.actionStems["remind_me"]!)]

    @Test(arguments: [
        "Listo, sacué la basura el viernes.",
        "Listo, revisé el horno.",
        "Listo, me acordé de llamar al banco.",
        "Listo, solo compraste leche y pan.",
        "Listo, saqué la basura.",
        "No tengo metas activas.",
        "Listo, he recordado revisar el horno para las 17:08.",
        "Listo, he recordado que llevaré el carro al taller.",
        "Listo, ya me he registrado para leer 12 libros.",
        "Listo, ya hice la meta de leer 12 libros.",
    ])
    func claimsAboutTheOwnersTaskAreRejected(text: String) {
        #expect(!OnDevicePromptBuilder.acceptsConfirmation(text, salient: Self.garbage))
    }

    @Test func aRealConfirmationPasses() {
        #expect(OnDevicePromptBuilder.acceptsConfirmation("Listo, el viernes a las 7 te recuerdo sacar la basura.",
                                                          salient: Self.garbage))
        #expect(OnDevicePromptBuilder.acceptsConfirmation("Listo, anoté la clave del wifi.",
                                                          salient: [.subject(["clav", "wifi"])]))
        #expect(OnDevicePromptBuilder.acceptsConfirmation("Listo, he registrado tu meta y te preguntaré cada domingo.",
                                                          salient: [SalientGroup(["meta"])]))
    }

    @Test func admissionsAreNegationsNotTheWordError() {
        #expect(!ToolFailureNotice.admits("Listo, quedó sin errores."))
        #expect(!ToolFailureNotice.admits("Todo salió sin fallos."))
        #expect(ToolFailureNotice.admits("Hubo un error al guardar."))
        #expect(ToolFailureNotice.admits("Lo siento, falló al crear el recordatorio."))
    }

    /// Redirect + reintento + éxito: el pliegue solo cuenta los pares exitosos.
    @Test func aRedirectFollowedBySuccessNeverLeaksTheError() throws {
        let ctx = AssembledContext(messages: [
            .user("recuérdame todos los días laborales a las 8 tomar la pastilla"),
            .assistant([.toolUse(id: "t1", name: "list_reminders", input: .object([:]))]),
            .user([.toolResult(toolUseId: "t1", content: "El dueño pidió crear algo, no consultar: usa remind_me. Corrige y llama remind_me otra vez. Ej: {}",
                               isError: true)]),
            .assistant([.toolUse(id: "t2", name: "remind_me", input: .object(["text": .string("tomar la pastilla")]))]),
            .user([.toolResult(toolUseId: "t2", content: "Listo: te recuerdo 'tomar la pastilla' entre semana. Id A-1.",
                               isError: false)]),
        ])
        let r = OnDevicePromptBuilder.request(ctx: ctx, tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(r.fallbackText == "Listo, te recuerdo 'tomar la pastilla' entre semana.")
        #expect(!r.prompt.contains("ERROR"))
        #expect(!(r.fallbackText ?? "").contains("ERROR"))
        #expect(r.history.isEmpty)
    }
}
