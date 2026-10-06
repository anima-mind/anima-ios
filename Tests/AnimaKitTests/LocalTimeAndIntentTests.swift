import Foundation
import GRDB
import Testing
@testable import AnimaKit

/// Horas que no se parten, intenciones que no se inventan y artefactos del
/// adapter que no cuentan como fallos del mundo.
@Suite struct LocalTimeAndIntentTests {
    static func real(_ name: String, _ input: [String: JSONValue], owner: String) -> JSONValue? {
        LocalOwnerRepairTests.real(name, input, owner: owner)
    }

    @Test(arguments: [
        ("recuérdame el 15 de octubre a las 10 de la mañana la cita", "2026-10-15 10:00", "2026-10-15T10:00:00"),
        ("recuérdame el 15 de octubre a las 3 de la tarde la cita", "2026-10-15 15:00", "2026-10-15T15:00:00"),
        ("recuérdame el 25 de diciembre a las 8 de la noche la cena", "2026-12-25 20:00", "2026-12-25T20:00:00"),
    ])
    func aDayOfMonthIsNeverAnHour(owner: String, model: String, expected: String) throws {
        let input = try #require(Self.real("remind_me", ["text": .string("x"), "when": .string(model),
                                                         "repeat": .string("none")], owner: owner))
        #expect(input["fire_at"] == .string(expected))
    }

    @Test func anEventRangeAfterADayOfMonth() throws {
        let event = try #require(Self.real("add_calendar_event", [
            "title": .string("dentista"), "start": .string("2026-10-15 14:00"), "end": .string("2026-10-15 15:00")],
            owner: "agéndame dentista el 15 de octubre de 2 a 3 de la tarde"))
        #expect(event["start"] == .string("2026-10-15T14:00:00"))
        #expect(event["end"] == .string("2026-10-15T15:00:00"))
    }

    @Test(arguments: ["elimina mi meta de correr", "borra mi meta", "ya cumplí mi meta de leer 12 libros",
                      "quiero cambiar mi meta", "cancela mi meta de ahorrar"])
    func changingAGoalIsNeverDeclaringOne(owner: String) {
        #expect(LocalToolAdapter.intended(name: "list_goals", ownerText: owner) == "list_goals")
        #expect(LocalToolAdapter.intended(name: "list_reminders", ownerText: owner) == "list_reminders")
    }

    @Test func onlyCreationPhrasingRedirectsToAGoal() {
        #expect(LocalToolAdapter.intended(name: "list_goals", ownerText: "mi meta es correr 10 km") == "declare_goal")
        #expect(LocalToolAdapter.intended(name: "list_goals", ownerText: "me propongo leer más") == "declare_goal")
        #expect(LocalToolAdapter.intended(name: "list_goals", ownerText: "mi meta de correr") == "list_goals")
    }

    @Test(arguments: [
        ("recuérdame dentro de 20 minutos sacar la ropa", "2026-10-06 10:31", "2026-10-06T10:50:00"),
        ("en una hora y media apaga el horno", "2026-10-06 10:31", "2026-10-06T12:00:00"),
        ("recuérdame dentro de 2 horas llamar", "2026-10-06 18:00", "2026-10-06T12:30:00"),
    ])
    func offsetsFromTheClock(owner: String, model: String, expected: String) throws {
        let input = try #require(Self.real("remind_me", ["text": .string("x"), "when": .string(model),
                                                         "repeat": .string("none")], owner: owner))
        #expect(input["fire_at"] == .string(expected))
    }

    @Test func aRerouteToRemindersKeepsTheOffset() throws {
        let input = try #require(Self.real("declare_goal", [
            "statement": .string("apagar el horno"), "checkin": .string("none"), "hour": .int(17)],
            owner: "recuérdame en 45 minutos apagar el horno"))
        #expect(input["action"] == .string("create"))
        #expect(input["fire_at"] == .string("2026-10-06T11:15:00"))
    }

    @Test(arguments: [
        ("recuérdame cada 15 días revisar la tarjeta", "2026-10-21T09:00:00"),
        ("recuérdame cada 2 semanas a las 8 pm regar", "2026-10-20T20:00:00"),
        ("recuérdame cada mes pagar el internet", "2026-11-06T09:00:00"),
        ("recuérdame el viernes a las 10, quincenal, la nómina", "2026-10-09T10:00:00"),
    ])
    func unsupportedRepetitionIsOnceAndSaid(owner: String, expected: String) throws {
        let input = try #require(Self.real("remind_me", ["text": .string("x"), "when": .string("2026-10-07 00:00"),
                                                         "repeat": .string("daily")], owner: owner))
        #expect(input["repeat"] == .string("none"))
        #expect(input["fire_at"] == .string(expected))
        let presented = LocalToolAdapter.present(ToolResult(content: "Listo: te recuerdo 'x'."), local: "remind_me",
                                                 input: input, ownerText: owner)
        #expect(presented.content.contains("aún no lo repito sola"))
    }

    @Test func aReminderWithoutAnHourGetsAPlausibleOne() throws {
        let night = try #require(Self.real("remind_me", ["text": .string("hoy fue un buen día"),
                                                         "when": .string("2026-10-07 00:00"), "repeat": .string("none")],
                                           owner: "recuérdame mañana que hoy fue un buen día"))
        #expect(night["fire_at"] == .string("2026-10-07T09:00:00"))
        let evening = try #require(Self.real("remind_me", ["text": .string("x"), "when": .string("2026-10-07 19:00"),
                                                           "repeat": .string("none")], owner: "recuérdame mañana x"))
        #expect(evening["fire_at"] == .string("2026-10-07T09:00:00"))
        let late = try #require(Self.real("remind_me", ["text": .string("x"), "when": .string("2026-10-07 23:30"),
                                                        "repeat": .string("none")], owner: "recuérdame mañana a las 11:30 pm x"))
        #expect(late["fire_at"] == .string("2026-10-07T23:30:00"))
    }

    @Test func eventsAreListedInLocalTimeWithoutIds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = LocalToolAdapterTests.bogota
        let raw = "- [ABC123:XYZ-9] Dentista @ 2026-10-07T20:52:00Z\n- [?] Almuerzo @ 2026-10-08T17:00:00Z"
        let shown = LocalToolAdapter.present(ToolResult(content: raw), local: "list_events", input: .object([:]),
                                             dates: AnimaDateText(calendar: calendar))
        #expect(shown.content == "- Dentista — miércoles 7 de octubre a las 15:52\n- Almuerzo — jueves 8 de octubre a las 12:00")
        #expect(OnDevicePromptBuilder.withoutListIds("- [ABC123:XYZ-9] x") == "- x")
    }

    @Test func permissionErrorsReadInSecondPerson() {
        #expect(ToolFailureNotice.legible("El dueño no ha concedido acceso al calendario.")
                == "no me has dado acceso al calendario")
    }

    @Test func spokenFallbackDropsExclamations() {
        #expect(LocalToolAdapter.spokenFallback("¡Mañana es el examen!") == "Oye, acuérdate de mañana es el examen.")
    }

    @Test func nounsInEAreNotPreterites() {
        #expect(OnDevicePromptBuilder.acceptsConfirmation("Listo, te recuerdo comprar café para José.",
                                                          salient: [.subject(["comp", "cafe"])]))
        #expect(!OnDevicePromptBuilder.acceptsConfirmation("Listo, compré café.", salient: [.subject(["comp", "cafe"])]))
    }

    @Test func anEmptyReadMustSayThereIsNothing() async throws {
        let ctx = AssembledContext(messages: [
            .user("quiero ver mis metas"),
            .assistant([.toolUse(id: "t1", name: "list_goals", input: .object([:]))]),
            .user([.toolResult(toolUseId: "t1", content: "No tienes metas activas.", isError: false)]),
        ])
        let session = MockOnDeviceSession([[.snapshot("¿Qué te gustaría que las metas fueran?")]])
        let provider = OnDeviceProvider(session: session, availability: { .available })
        let response = try await provider.completeCollecting(ctx, tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(response.content == [.text("No tienes metas activas.")])
    }

    /// 3 turnos con redirect + éxito: nada llega al RealRegister y el 4.º turno
    /// no se rutea a RESTRUCTURE.
    @Test func adapterRedirectsAreNotWorldFailures() async throws {
        let w = try ProactiveFixtures.world()
        let register = RealRegister(queue: w.queue)
        let model = OnDeviceProvider.modelName
        var scripts: [[ProviderEvent]] = []
        for i in 0..<3 {
            scripts.append(LocalLoopHarness.toolUse("r\(i)", "list_reminders", "{}", model: model))
            scripts.append(LocalLoopHarness.toolUse("c\(i)", "remind_me",
                                                    #"{"text":"x\#(i)","when":"2030-01-0\#(i + 2) 09:00","repeat":"none"}"#,
                                                    model: model))
            scripts.append(LocalLoopHarness.text("Listo, te recuerdo x."))
        }
        scripts.append(LocalLoopHarness.text("Hola."))
        let provider = CapturingProvider(scripts)
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: try OnDeviceTestConfig.router(), authMode: .apiKey, token: "",
                             clientTools: [AnimaRemindersTool(store: w.reminders)], serverTools: [],
                             permissionPolicy: .app(ownerAllowlist: { [] }), realRegister: register, sleep: { _ in })
        let sid = try store.startSession()
        for i in 0..<3 {
            for await _ in await loop.run(sessionId: sid, userText: "recuérdame el \(i + 2) de enero a las 9 x\(i)") {}
        }
        #expect(await register.demand().isEmpty)
        #expect(await w.reminders.list().count == 3)
        for await _ in await loop.run(sessionId: sid, userText: "hola") {}
        let last = try #require(provider.captures.value.last)
        #expect(!last.messages.contains { OnDevicePromptBuilder.plainText($0.content).contains("[RESTRUCTURE]") })
    }
}

@Suite struct LocalReminderTextTests {
    @Test(arguments: [
        ("recuérdame hoy a las 6 de la tarde que mañana es el examen", "mañana es el examen"),
        ("recuérdame mañana a las 9 llamar al banco", "llamar al banco"),
        ("Recuérdame el viernes a las 7 de la noche sacar la basura", "sacar la basura"),
        ("recuérdame dentro de 20 minutos sacar la ropa", "sacar la ropa"),
        ("recuérdame cada 15 días revisar la tarjeta", "revisar la tarjeta"),
        ("recuérdame el 15 de octubre a las 10 de la mañana la cita", "la cita"),
        ("recuérdame el examen", "el examen"),
    ])
    func dictatedText(owner: String, expected: String) {
        #expect(LocalToolAdapter.dictatedReminder(owner) == expected)
    }

    @Test func anUnrelatedModelTextIsReplaced() {
        let owner = "recuérdame hoy a las 6 de la tarde que mañana es el examen"
        #expect(LocalToolAdapter.reminderText(model: "tomar la pastilla", ownerText: owner) == "mañana es el examen")
        #expect(LocalToolAdapter.reminderText(model: "examen", ownerText: owner) == "examen")
        #expect(LocalToolAdapter.reminderText(model: "x", ownerText: "") == "x")
    }

    @Test func aReminderAskedAsAnEventIsAReminder() throws {
        let r = LocalToolAdapter.resolve(name: "add_calendar_event", input: .object([
            "title": .string("Cita"), "start": .string("2026-10-15 10:00"), "end": .string("2026-10-15 11:00")]),
            now: LocalToolAdapterTests.now, ownerText: "recuérdame el 15 de octubre a las 10 de la mañana la cita",
            calendar: LocalToolAdapterTests.calendar)
        guard case .real(let name, let input) = r else { Issue.record("debió traducir"); return }
        #expect(name == "anima_reminders")
        #expect(input["fire_at"] == .string("2026-10-15T10:00:00"))
        let agenda = LocalToolAdapter.resolve(name: "add_calendar_event", input: .object([
            "title": .string("Cita"), "start": .string("2026-10-15 10:00"), "end": .string("2026-10-15 11:00")]),
            now: LocalToolAdapterTests.now, ownerText: "agéndame la cita del 15 de octubre a las 10 y recuérdamela",
            calendar: LocalToolAdapterTests.calendar)
        guard case .real(let agendaName, _) = agenda else { Issue.record("debió traducir"); return }
        #expect(agendaName == "calendar")
    }

    @Test func aRerouteFromAGoalSaidOnceDoesNotRepeat() throws {
        let input = try #require(LocalOwnerRepairTests.real("declare_goal", [
            "statement": .string("tomar la pastilla"), "checkin": .string("daily"), "hour": .int(18)],
            owner: "recuérdame hoy a las 6 de la tarde que mañana es el examen"))
        #expect(input["repeat"] == .string("none"))
        #expect(input["text"] == .string("mañana es el examen"))
        #expect(input["fire_at"] == .string("2026-10-06T18:00:00"))
    }
}

@Suite struct LocalChangeRequestTests {
    @Test func aChangeRequestSaysWhereItIsDone() async throws {
        let shown = LocalToolAdapter.present(ToolResult(content: "- [G1] correr 10 km (stated, x)"), local: "list_goals",
                                             input: .object([:]), ownerText: "elimina mi meta de correr")
        #expect(shown.content == "Eso no lo puedo cambiar desde aquí: hazlo en la tab Metas. Lo que hay:\n- correr 10 km")
        let ctx = AssembledContext(messages: [
            .user("elimina mi meta de correr"),
            .assistant([.toolUse(id: "t1", name: "list_goals", input: .object([:]))]),
            .user([.toolResult(toolUseId: "t1", content: shown.content, isError: false)]),
        ])
        let session = MockOnDeviceSession([[.snapshot("La meta de correr 10 km ya no está en el registro.")]])
        let provider = OnDeviceProvider(session: session, availability: { .available })
        let response = try await provider.completeCollecting(ctx, tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(response.content == [.text(shown.content)])
        #expect(LocalToolAdapter.present(ToolResult(content: "x"), local: "list_reminders", input: .object([:]),
                                         ownerText: "¿qué tengo?").content == "x")
    }
}

@Suite struct LocalChangeIntentTests {
    @Test(arguments: ["recuérdame el viernes cambiar el aceite del carro", "recuérdame el viernes cancelar Netflix",
                      "recuérdame en 20 minutos quitar la ropa", "anota que hay que borrar los correos viejos"])
    func aCreationWithAChangeVerbIsStillACreation(owner: String) {
        #expect(!LocalWhen.asksToChange(owner))
        #expect(LocalToolAdapter.intended(name: "list_reminders", ownerText: owner) != "list_reminders")
        #expect(LocalToolAdapter.changeNote(owner, tab: "Metas").isEmpty)
    }

    @Test(arguments: ["elimina mi meta de correr", "ya cumplí mi meta de leer", "borra el recordatorio del banco",
                      "quiero cambiar mi meta", "cancela la cita del dentista", "ya no quiero esa meta"])
    func aChangeRequest(owner: String) {
        #expect(LocalWhen.asksToChange(owner))
        #expect(LocalWhen.changeHint(owner) != nil)
    }

    @Test func hintsPointToTheRightPlace() {
        #expect(LocalWhen.changeHint("ya cumplí mi meta de leer") == "Márcala como lograda en la tab Metas.")
        #expect(LocalWhen.changeHint("borra el recordatorio del banco") == "Eso lo borras en la tab Recordatorios.")
        #expect(LocalWhen.changeHint("recuérdame cambiar el aceite") == nil)
    }

    @Test func aToolLessTurnAboutAChangeSaysWhere() async throws {
        let r = try await LocalLoopHarness.run([LocalLoopHarness.text("¡Felicidades por cumplir tu meta!")], tools: [],
                                               router: try OnDeviceTestConfig.router(), text: "ya cumplí mi meta de leer")
        #expect(r.text == "¡Felicidades por cumplir tu meta!\nMárcala como lograda en la tab Metas.")
        #expect(try r.lastAssistantText().hasSuffix("Márcala como lograda en la tab Metas."))
    }

    @Test func monthlyFromTheModelIsOnceNotAnError() throws {
        let input = try #require(LocalOwnerRepairTests.real("remind_me", [
            "text": .string("pagar el arriendo"), "when": .string("2026-11-01 09:00"), "repeat": .string("monthly")],
            owner: "recuérdame cada mes pagar el arriendo"))
        #expect(input["repeat"] == .string("none"))
        #expect(input["fire_at"] == .string("2026-11-06T09:00:00"))
        let every = try #require(LocalOwnerRepairTests.real("remind_me", [
            "text": .string("x"), "when": .string("2026-10-07 09:00"), "repeat": .string("every 2 weeks")], owner: ""))
        #expect(every["repeat"] == .string("none"))
    }

    @Test func noonIsNotMidnight() throws {
        let input = try #require(LocalOwnerRepairTests.real("remind_me", [
            "text": .string("x"), "when": .string("2026-10-07 00:00"), "repeat": .string("none")],
            owner: "recuérdame mañana a las 12 almorzar"))
        #expect(input["fire_at"] == .string("2026-10-07T12:00:00"))
    }

    @Test(arguments: [
        ("agéndame almuerzo con Ana el 22 de octubre de 12 a 1", "2026-10-22 13:00", "2026-10-22 12:00",
         "2026-10-22T12:00:00", "2026-10-22T13:00:00"),
        ("agéndame reunión el jueves de 2 a 3", "2026-10-08 14:00", "2026-10-08 15:00",
         "2026-10-08T14:00:00", "2026-10-08T15:00:00"),
        ("agéndame taller el jueves de 9 a 11", "2026-10-08 09:00", "2026-10-08 11:00",
         "2026-10-08T09:00:00", "2026-10-08T11:00:00"),
        ("agéndame algo el jueves", "2026-10-08 16:00", "2026-10-08 15:00",
         "2026-10-08T15:00:00", "2026-10-08T16:00:00"),
    ])
    func eventRanges(owner: String, start: String, end: String, expectedStart: String, expectedEnd: String) throws {
        let input = try #require(LocalOwnerRepairTests.real("add_calendar_event", [
            "title": .string("x"), "start": .string(start), "end": .string(end)], owner: owner))
        #expect(input["start"] == .string(expectedStart))
        #expect(input["end"] == .string(expectedEnd))
    }

    @Test func unsupportedPhraseKeepsTheAccents() {
        let when = LocalWhen(now: LocalToolAdapterTests.now, calendar: LocalToolAdapterTests.calendar,
                             ownerText: "Recuérdame cada 15 días revisar la tarjeta")
        #expect(when.unsupportedCadence?.phrase == "cada 15 días")
    }

    @Test func theConfirmationMustAgreeWithWhatWasSaved() {
        let saved = "Listo: te recuerdo 'examen' el martes 6 de octubre a las 18:00."
        let now = LocalToolAdapterTests.now
        let cal = LocalToolAdapterTests.calendar
        #expect(OnDevicePromptBuilder.agreesWithTheResult("Listo, hoy a las 6 de la tarde te recuerdo el examen.",
                                                          fallback: saved, now: now, calendar: cal))
        #expect(!OnDevicePromptBuilder.agreesWithTheResult("Listo, te recuerdo mañana a las 6 el examen.",
                                                           fallback: saved, now: now, calendar: cal))
        #expect(!OnDevicePromptBuilder.agreesWithTheResult("Listo, el jueves te recuerdo el examen.",
                                                           fallback: saved, now: now, calendar: cal))
        #expect(!OnDevicePromptBuilder.agreesWithTheResult("Listo, hoy a las 5 te recuerdo el examen.",
                                                           fallback: saved, now: now, calendar: cal))
        #expect(OnDevicePromptBuilder.agreesWithTheResult("Listo.", fallback: "Anotado.", now: now, calendar: cal))
        #expect(OnDevicePromptBuilder.confirmation(results: ["te diré: «Oye, x.»."]) == "Listo, te diré: «Oye, x».")
    }
}

@Suite struct LocalStopRemindingTests {
    @Test(arguments: [
        ("ya no quiero que me recuerdes lo del banco", "Eso lo borras en la tab Recordatorios."),
        ("deja de recordarme tomar agua", "Eso lo borras en la tab Recordatorios."),
        ("no me recuerdes más lo del gimnasio", "Eso lo borras en la tab Recordatorios."),
        ("elimina la cita de la agenda", "Eso lo borras en tu app Calendario."),
    ])
    func stoppingIsAChange(owner: String, hint: String) {
        #expect(LocalWhen.asksToChange(owner))
        #expect(LocalWhen.changeHint(owner) == hint)
        #expect(!LocalWhen(now: Date(), calendar: .current, ownerText: owner).ownerAsksForAReminder)
        #expect(LocalToolAdapter.intended(name: "list_reminders", ownerText: owner) == "list_reminders")
    }

    @Test func aCreationThatCancelsSomethingStillCreates() {
        #expect(!LocalWhen.asksToChange("recuérdame cancelar Netflix el viernes"))
        #expect(!LocalWhen.asksToChange("Oye, agéndame cancelar la tarjeta"))
    }

    @Test func aReadOnlyTurnAboutAChangeSaysWhere() async throws {
        let w = try ProactiveFixtures.world()
        let model = OnDeviceProvider.modelName
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "list_reminders", "{}", model: model),
            LocalLoopHarness.text("Tienes estos recordatorios."),
        ], tools: [AnimaRemindersTool(store: w.reminders)], router: try OnDeviceTestConfig.router(),
           policy: .app(ownerAllowlist: { [] }), text: "deja de recordarme tomar agua")
        #expect(r.text.hasSuffix("Eso lo borras en la tab Recordatorios."))
    }

    @Test func aDayRangeIsNotAnHourRange() throws {
        let when = LocalWhen(now: LocalToolAdapterTests.now, calendar: LocalToolAdapterTests.calendar,
                             ownerText: "agéndame vacaciones de 5 a 10 de octubre")
        #expect(when.ownerRange == nil)
    }

    @Test func invertedEventTitlesUseTheDictatedOne() throws {
        let input = try #require(LocalOwnerRepairTests.real("add_calendar_event", [
            "title": .string("Reunión de equipo"), "start": .string("2026-10-12 15:00"), "end": .string("2026-10-12 16:00")],
            owner: "agéndame reunión el lunes de 3 a 4"))
        #expect(input["title"] == .string("Reunión"))
        #expect(input["start"] == .string("2026-10-12T15:00:00"))
        #expect(LocalToolAdapter.eventTitle(model: "Almuerzo con Ana", ownerText: "agéndame almuerzo con Ana el jueves")
                == "Almuerzo con Ana")
    }

    @Test func aPassedTimeTodayMovesToTomorrowAndSaysSo() throws {
        let input = try #require(LocalOwnerRepairTests.real("remind_me", [
            "text": .string("almorzar"), "when": .string("2026-10-06 09:00"), "repeat": .string("none")],
            owner: "recuérdame hoy a las 9 almorzar"))
        #expect(input["fire_at"] == .string("2026-10-07T09:00:00"))
    }

    @Test func listsAreDeliveredAsIs() async throws {
        let ctx = AssembledContext(messages: [
            .user("¿qué metas tengo?"),
            .assistant([.toolUse(id: "t1", name: "list_goals", input: .object([:]))]),
            .user([.toolResult(toolUseId: "t1", content: "- correr una maratón — te pregunto cada domingo a las 20:00",
                               isError: false)]),
        ])
        let session = MockOnDeviceSession([[.snapshot("Tienes dos metas: correr y nadar.")]])
        let provider = OnDeviceProvider(session: session, availability: { .available })
        let response = try await provider.completeCollecting(ctx, tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(response.content == [.text("- correr una maratón — te pregunto cada domingo a las 20:00")])
        #expect(session.requests.value.isEmpty)
    }
}

@Suite struct LocalPendingTests {
    static let now = LocalToolAdapterTests.now
    static var dates: AnimaDateText { AnimaDateText(calendar: LocalToolAdapterTests.calendar) }

    @Test(arguments: [("¿qué tengo pendiente?", true), ("qué tengo hoy", true), ("¿qué hay para hoy?", true),
                      ("¿qué recordatorios tengo?", false), ("¿qué metas tengo?", false),
                      ("elimina lo pendiente", false)])
    func pendingQuestions(owner: String, expected: Bool) {
        #expect(LocalToolAdapter.asksForPending(owner) == expected)
    }

    @Test func theSummaryCombinesSectionsAndSkipsEmptyOnes() {
        let summary = LocalToolAdapter.pendingSummary(
            reminders: "Programados:\n- [R-1] llamar al banco — miércoles 7 de octubre a las 09:00",
            goals: "- [G-1] leer 12 libros (stated, x); check-in cada domingo a las 20:00",
            events: "- [E:1] Dentista @ 2026-10-06T20:00:00Z\n- [E:2] Otro día @ 2026-10-08T20:00:00Z",
            now: Self.now, dates: Self.dates)
        #expect(summary == """
            Recordatorios:
            - llamar al banco — miércoles 7 de octubre a las 09:00
            Metas:
            - leer 12 libros — te pregunto cada domingo a las 20:00
            Hoy en tu agenda:
            - Dentista — martes 6 de octubre a las 15:00
            """)
        #expect(LocalToolAdapter.pendingSummary(reminders: "No tienes recordatorios de Anima.",
                                                goals: "El dueño no tiene metas activas.", events: nil,
                                                now: Self.now, dates: Self.dates) == "No tienes nada pendiente hoy.")
        #expect(LocalToolAdapter.pendingSummary(reminders: nil, goals: "- [G] correr (s, x)", events: "No hay eventos.",
                                                now: Self.now, dates: Self.dates) == "Metas:\n- correr")
    }

    @Test func thePendingTurnListsEverything() async throws {
        let w = try ProactiveFixtures.world()
        _ = try await w.reminders.create(text: "llamar al banco", fireAt: Date().addingTimeInterval(86_400 * 400))
        _ = await w.other.ingestStated(statement: "leer 12 libros", desiredState: .progressCheckIn(everyDays: 8),
                                       evidence: "test")
        let model = OnDeviceProvider.modelName
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "list_reminders", "{}", model: model),
            LocalLoopHarness.text("ignorado"),
        ], tools: [AnimaRemindersTool(store: w.reminders), GoalsTool(otherModel: w.other)],
           router: try OnDeviceTestConfig.router(), text: "¿qué tengo pendiente?")
        let window = try r.store.window(sessionId: r.sid)
        let result = window.flatMap(\.content).compactMap { block -> String? in
            if case .toolResult(_, let content, false) = block { return content } else { return nil }
        }.first ?? ""
        #expect(result.contains("Recordatorios:\n- llamar al banco"))
        #expect(result.contains("Metas:\n- leer 12 libros"))
        #expect(!result.contains("Hoy en tu agenda"))
    }

    @Test func notesAndTitles() {
        #expect(LocalToolAdapter.pastTodayNote() == "Ojo: esa hora de hoy ya pasó, así que te lo puse para mañana.")
        #expect(LocalToolAdapter.dictatedEvent("Agéndame reunión con Pedro el próximo martes a las 3") == "reunión con Pedro")
        #expect(LocalToolAdapter.dictatedEvent("agéndame revisión con Ana la próxima semana") == "revisión con Ana")
        #expect(LocalToolAdapter.eventTitle(model: "Reunión de equipo", ownerText: "agéndame reunión con Pedro el jueves")
                == "Reunión con Pedro")
    }
}

@Suite struct LocalPendingScopeTests {
    @Test(arguments: [("qué tengo mañana", false), ("¿qué hay esta semana?", false), ("qué tengo el viernes", false),
                      ("¿qué tengo?", true), ("¿qué tengo para hoy?", true), ("¿qué hay hoy?", true),
                      ("¿tengo algo pendiente?", true),
                      ("recuérdame qué tengo que comprar mañana a las 6", false),
                      ("anota qué hay en la nevera: leche y huevos", false)])
    func pendingOnlyForTodayOrBare(owner: String, expected: Bool) {
        #expect(LocalToolAdapter.asksForPending(owner) == expected)
    }

    @Test func aCreationOpeningIsNeverAQuery() {
        #expect(LocalToolAdapter.intended(name: "list_reminders", ownerText: "recuérdame qué tengo que comprar mañana a las 6")
                == "remind_me")
        #expect(LocalToolAdapter.intended(name: "read_note", ownerText: "anota qué hay en la nevera: leche y huevos")
                == "write_note")
    }

    @Test func eventListsRespectTheRequestedDay() {
        let when = LocalWhen(now: LocalToolAdapterTests.now, calendar: LocalToolAdapterTests.calendar,
                             ownerText: "¿qué tengo mañana?")
        #expect(when.listDaysAhead == 2)
        let raw = "- [E:1] Hoy @ 2026-10-06T20:00:00Z\n- [E:2] Dentista @ 2026-10-07T15:00:00Z"
        #expect(when.eventsInRequestedRange(raw) == "- [E:2] Dentista @ 2026-10-07T15:00:00Z")
        let week = LocalWhen(now: LocalToolAdapterTests.now, calendar: LocalToolAdapterTests.calendar,
                             ownerText: "qué hay esta semana")
        #expect(week.listDaysAhead == 6)
        #expect(week.eventsInRequestedRange(raw) == raw)
        let friday = LocalWhen(now: LocalToolAdapterTests.now, calendar: LocalToolAdapterTests.calendar,
                               ownerText: "qué tengo el viernes")
        #expect(friday.listDaysAhead == 4)
        #expect(friday.eventsInRequestedRange(raw) == "No tienes nada en tu agenda el viernes 9 de octubre.")
        let input = LocalOwnerRepairTests.real("list_events", ["days": .int(1)], owner: "qué hay esta semana")
        #expect(input?["days_ahead"] == .int(6))
    }

    @Test(arguments: [
        ("agéndame cena con Laura la próxima semana el viernes a las 8 de la noche", "2026-10-16T20:00:00"),
        ("agéndame cena con Laura el viernes de la otra semana a las 8 de la noche", "2026-10-16T20:00:00"),
        ("agéndame revisión la semana que viene el lunes a las 9 am", "2026-10-12T09:00:00"),
    ])
    func nextWeekPlusDay(owner: String, expected: String) throws {
        let input = try #require(LocalOwnerRepairTests.real("add_calendar_event", [
            "title": .string("x"), "start": .string("2026-10-09 20:00"), "end": .string("2026-10-09 21:00")], owner: owner))
        #expect(input["start"] == .string(expected))
    }

    @Test func nextWeekWithoutADayIsMonday() throws {
        let input = try #require(LocalOwnerRepairTests.real("remind_me", [
            "text": .string("x"), "when": .string("2026-10-07 18:00"), "repeat": .string("none")],
            owner: "recuérdame la próxima semana pagar el seguro"))
        #expect(input["fire_at"] == .string("2026-10-12T09:00:00"))
    }

    @Test func eventTitleCutsOnlyOnTheNextWeek() {
        #expect(LocalToolAdapter.dictatedEvent("agéndame regalo para la mamá el viernes") == "regalo para la mamá")
        #expect(LocalToolAdapter.dictatedEvent("agéndame cena con Laura para la próxima semana") == "cena con Laura")
    }

    @Test func aScheduledEventIsConfirmedWithWhatWasSaved() async throws {
        let ctx = AssembledContext(messages: [
            .user("agéndame cena con Laura"),
            .assistant([.toolUse(id: "t1", name: "add_calendar_event", input: .object(["title": .string("cena con Laura")]))]),
            .user([.toolResult(toolUseId: "t1", content: "agendé «Cena con Laura» el viernes 16 de octubre de 20:00 a 21:00.",
                               isError: false)]),
        ])
        let session = MockOnDeviceSession([[.snapshot("Listo, agendé la cena con Laura en el restaurante La Terraza.")]])
        let provider = OnDeviceProvider(session: session, availability: { .available })
        let response = try await provider.completeCollecting(ctx, tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(response.content == [.text("Listo, agendé «Cena con Laura» el viernes 16 de octubre de 20:00 a 21:00.")])
        #expect(session.requests.value.isEmpty)
    }
}


@Suite struct LocalPendingRangeTests {
    static let now = LocalToolAdapterTests.now
    static var dates: AnimaDateText { AnimaDateText(calendar: LocalToolAdapterTests.calendar) }
    static func range(_ owner: String) -> LocalWhen.Range? {
        LocalWhen(now: now, calendar: LocalToolAdapterTests.calendar, ownerText: owner).requestedRange
    }
    static let reminders = "Programados:\n- [R1] pagar la luz — miércoles 7 de octubre a las 09:00\n- [R2] cita — viernes 9 de octubre a las 10:00"
    static let events = "- [E:1] Dentista @ 2026-10-07T20:00:00Z\n- [E:2] Fútbol @ 2026-10-09T20:00:00Z\n- [E:3] Lunes @ 2026-10-12T14:00:00Z"

    @Test func pendingForTomorrow() {
        let summary = LocalToolAdapter.pendingSummary(reminders: Self.reminders, goals: nil, events: Self.events, now: Self.now,
                                                      range: Self.range("¿qué tengo pendiente para mañana?"), dates: Self.dates)
        #expect(summary == "Recordatorios:\n- pagar la luz — miércoles 7 de octubre a las 09:00\nMañana en tu agenda:\n- Dentista — miércoles 7 de octubre a las 15:00")
    }

    @Test func pendingOnFriday() {
        let summary = LocalToolAdapter.pendingSummary(reminders: Self.reminders, goals: nil, events: Self.events, now: Self.now,
                                                      range: Self.range("pendientes el viernes"), dates: Self.dates)
        #expect(summary.contains("- cita — viernes 9") && summary.contains("- Fútbol") && !summary.contains("Dentista"))
        #expect(summary.contains("El viernes 9 de octubre en tu agenda:"))
    }

    @Test func pendingThisWeekStopsOnSunday() {
        let summary = LocalToolAdapter.pendingSummary(reminders: Self.reminders, goals: nil, events: Self.events, now: Self.now,
                                                      range: Self.range("¿qué tengo pendiente esta semana?"), dates: Self.dates)
        #expect(summary.contains("Dentista") && summary.contains("Fútbol") && !summary.contains("Lunes"))
        #expect(LocalWhen(now: Self.now, calendar: LocalToolAdapterTests.calendar, ownerText: "qué hay esta semana")
                    .eventsInRequestedRange(Self.events).contains("Lunes") == false)
    }

    @Test func emptyRangeSaysSo() {
        #expect(LocalToolAdapter.pendingSummary(reminders: nil, goals: nil, events: nil, now: Self.now,
                                                range: Self.range("pendiente para mañana"), dates: Self.dates)
                == "No tienes nada pendiente mañana.")
    }

    @Test(arguments: [("Pagar el viernes a las 9", "Pagar"), ("llamar a mamá mañana", "llamar a mamá"),
                      ("Mañana es el examen", "Mañana es el examen"), ("revisar el horno en 2 horas", "revisar el horno")])
    func reminderTitlesWithoutSchedule(text: String, expected: String) {
        #expect(LocalToolAdapter.withoutSchedule(text) == expected)
    }
}

@Suite struct LocalQueryToolTests {
    @Test(arguments: [("qué hay esta semana", "list_reminders"), ("¿qué metas tengo?", "list_goals"),
                      ("¿qué recordatorios tengo?", "list_reminders"), ("¿qué citas tengo el viernes?", "list_events"),
                      ("hola", nil), ("recuérdame qué tengo que comprar", nil), ("elimina mi meta", nil)])
    func queryTools(owner: String, expected: String?) {
        #expect(LocalToolAdapter.queryTool(owner) == expected)
    }

    @Test func summaryOnlyWithoutACategory() {
        #expect(LocalToolAdapter.asksForSummary("qué hay esta semana"))
        #expect(LocalToolAdapter.asksForSummary("¿qué tengo mañana?"))
        #expect(!LocalToolAdapter.asksForSummary("¿qué metas tengo?"))
        #expect(!LocalToolAdapter.asksForSummary("¿qué citas tengo el viernes?"))
    }

    @Test func anAnswerWithoutToolBecomesTheQuery() async throws {
        let session = MockOnDeviceSession([[.snapshot("Esta semana tienes Almuerzo con Ana.")]])
        let provider = OnDeviceProvider(session: session, availability: { .available })
        let response = try await provider.completeCollecting(AssembledContext(messages: [.user("qué hay esta semana")]),
                                                             tools: try RealToolSet.specs(), opts: try OnDeviceTestConfig.opts())
        #expect(response.stopReason == .toolUse)
        #expect(response.toolCalls.first?.name == "list_reminders")
        #expect(response.content.allSatisfy { if case .text = $0 { false } else { true } })
    }

    @Test func aReminderAskedAsANoteIsAReminder() throws {
        let input = try #require(LocalOwnerRepairTests.real("write_note", [
            "name": .string("horno"), "content": .string("apagar el horno")], owner: "recuérdame en 45 minutos apagar el horno"))
        #expect(input["action"] == .string("create"))
        #expect(input["fire_at"] == .string("2026-10-06T11:15:00"))
    }
}
