import Foundation
import Testing
@testable import AnimaKit

// El modelo de Apple ve tools de UNA intención; el adapter las traduce
// a las reales con validación tolerante y fechas en hora de pared local.

@Suite struct LocalToolAdapterTests {
    /// Martes 6 de octubre de 2026, 10:30 en Bogotá.
    static let bogota = TimeZone(identifier: "America/Bogota")!
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = bogota
        return c
    }
    static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 10, minute: 30))!

    static func resolve(_ name: String, _ input: [String: JSONValue], owner: String = "") -> LocalToolAdapter.Resolution {
        LocalToolAdapter.resolve(name: name, input: .object(input), now: now, ownerText: owner, calendar: calendar)
    }

    static func real(_ resolution: LocalToolAdapter.Resolution) -> (String, JSONValue)? {
        if case .real(let name, let input) = resolution { return (name, input) }
        return nil
    }

    static func message(_ resolution: LocalToolAdapter.Resolution) -> String? {
        if case .invalid(_, let message) = resolution { return message }
        return nil
    }

    // MARK: traducción

    @Test func remindMeBecomesAnimaRemindersCreateInLocalWallTime() throws {
        let (name, input) = try #require(Self.real(Self.resolve("remind_me", [
            "text": .string(" llamar al banco "), "when": .string("2026-10-07 09:00"), "repeat": .string("none")])))
        #expect(name == "anima_reminders")
        #expect(input == .object([
            "action": .string("create"), "text": .string("llamar al banco"),
            "message": .string("Oye, acuérdate de llamar al banco."),
            "fire_at": .string("2026-10-07T09:00:00"), "repeat": .string("none"),
        ]))
    }

    /// El 3B no sabe de zonas: Z u offset se ignoran, cuenta la hora de pared.
    @Test(arguments: ["2026-10-07 09:00", "2026-10-07T09:00:00Z", "2026-10-07T09:00:00+02:00",
                      "2026-10-07T09:00", "2026-10-07 9:00", "mañana a las 9", "miércoles 9:00 am"])
    func whenIsAlwaysLocalWallTime(raw: String) throws {
        let (_, input) = try #require(Self.real(Self.resolve("remind_me", [
            "text": .string("x"), "when": .string(raw), "repeat": .string("none")])))
        #expect(input["fire_at"] == .string("2026-10-07T09:00:00"))
    }

    @Test func theRealToolReadsTheTranslatedDateAsLocal() async throws {
        let w = try ProactiveFixtures.world()
        let tool = AnimaRemindersTool(store: w.reminders, timeZone: Self.bogota)
        let (_, input) = try #require(Self.real(LocalToolAdapter.resolve(
            name: "remind_me", input: .object(["text": .string("x"), "when": .string("2030-01-02T09:00:00Z"),
                                               "repeat": .string("no")]),
            now: Self.now, calendar: Self.calendar)))
        let result = await tool.execute(input)
        #expect(!result.isError, "\(result.content)")
        let reminder = try #require(await w.reminders.list().first)
        #expect(Self.calendar.component(.hour, from: reminder.fireAt) == 9)
        #expect(reminder.message == "Oye, acuérdate de x.")
    }

    @Test(arguments: [("diario", "daily"), ("Semanal", "weekly"), ("ninguno", "none"), ("no", "none"),
                      ("", "none"), ("entre semana", "weekdays"), (" WEEKLY ", "weekly"), ("cada día", "daily")])
    func repeatSynonymsNormalize(raw: String, expected: String) throws {
        let (_, input) = try #require(Self.real(Self.resolve("remind_me", [
            "text": .string("x"), "when": .string("2026-10-07 09:00"), "repeat": .string(raw)])))
        #expect(input["repeat"] == .string(expected))
    }

    @Test func missingRepeatDefaultsToNoneAndRepeatingPastTimeRollsForward() throws {
        let (_, once) = try #require(Self.real(Self.resolve("remind_me", [
            "text": .string("x"), "when": .string("2026-10-07 09:00")])))
        #expect(once["repeat"] == .string("none"))
        // "todos los días a las 8" dicho a las 10:30: la primera vez es mañana.
        let (_, daily) = try #require(Self.real(Self.resolve("remind_me", [
            "text": .string("tomar agua"), "when": .string("2026-10-06 08:00"), "repeat": .string("daily")])))
        #expect(daily["fire_at"] == .string("2026-10-07T08:00:00"))
        let (_, weekly) = try #require(Self.real(Self.resolve("remind_me", [
            "text": .string("x"), "when": .string("2026-10-06 08:00"), "repeat": .string("weekly")])))
        #expect(weekly["fire_at"] == .string("2026-10-13T08:00:00"))
    }

    @Test func missingFieldsGiveShortActionableErrors() {
        #expect(Self.message(Self.resolve("remind_me", ["when": .string("2026-10-07 09:00")]))?.contains("`text`") == true)
        let noWhen = Self.message(Self.resolve("remind_me", ["text": .string("x"), "when": .string("pronto")]))
        #expect(noWhen == "Falta `when` o no se entiende: formato 'YYYY-MM-DD HH:MM', hora local.")
        #expect(Self.message(Self.resolve("remind_me", ["text": .string("x"), "when": .string("2026-10-07")]))?
            .contains("`when`") == true)
        #expect(Self.message(Self.resolve("remind_me", ["text": .string("x"), "when": .string("2026-02-30 09:00")]))?
            .contains("`when`") == true)
        // Una repetición que la app no hace nunca es un error: una vez.
        #expect(Self.real(Self.resolve("remind_me", [
            "text": .string("x"), "when": .string("2026-10-07 09:00"), "repeat": .string("monthly")]))?.1["repeat"]
            == .string("none"))
        #expect(Self.message(Self.resolve("declare_goal", ["checkin": .string("weekly")]))?.contains("`statement`") == true)
        #expect(Self.message(Self.resolve("add_calendar_event", ["start": .string("2026-10-08 15:00")]))?
            .contains("`title`") == true)
        #expect(Self.message(Self.resolve("add_calendar_event", ["title": .string("x")]))?.contains("`start`") == true)
        #expect(Self.message(Self.resolve("write_note", ["name": .string("x")]))?.contains("`content`") == true)
        #expect(Self.message(Self.resolve("camera", [:]))?.hasPrefix("No existe la herramienta 'camera'") == true)
        guard case .invalid(let tool, _) = Self.resolve("remind_me", [:]) else { Issue.record("debió fallar"); return }
        #expect(tool == "anima_reminders")
    }

    @Test func retryHintCarriesTheLiteralExample() {
        let hint = LocalToolAdapter.retryHint(tool: "remind_me", message: "Falta `when`.")
        #expect(hint == "Falta `when`. Corrige y llama remind_me otra vez. Ej: {text:'tomar la pastilla', when:'2026-10-07 08:00', repeat:'none'}")
        #expect(LocalToolAdapter.retryHint(tool: "otra", message: "m") == "m")
    }

    @Test func declareGoalAddsTheCheckInOnlyWhenAsked() throws {
        let (name, input) = try #require(Self.real(Self.resolve("declare_goal", [
            "statement": .string("bajar 5 kilos"), "checkin": .string("semanal"), "hour": .int(0)],
            owner: "quiero bajar 5 kilos, pregúntame cada semana cómo voy")))
        #expect(name == "goals")
        // Sin hora dicha por el dueño, la del modelo (0) es invento: 20:00.
        #expect(input == .object([
            "action": .string("declare"), "statement": .string("bajar 5 kilos"),
            "checkin": .object(["cadence": .string("weekly"), "hour": .int(20)]),
        ]))
        let (_, explicit) = try #require(Self.real(Self.resolve("declare_goal", [
            "statement": .string("leer"), "checkin": .string("daily"), "hour": .string("8")],
            owner: "quiero leer, pregúntame cada día a las 8 pm")))
        #expect(explicit["checkin"]?["hour"] == .int(20))
        let (_, said) = try #require(Self.real(Self.resolve("declare_goal", [
            "statement": .string("leer"), "checkin": .string("daily"), "hour": .int(7)],
            owner: "pregúntame a las 7")))
        #expect(said["checkin"]?["hour"] == .int(7))
        let (_, none) = try #require(Self.real(Self.resolve("declare_goal", [
            "statement": .string("leer"), "checkin": .string("none"), "hour": .int(20)])))
        #expect(none["checkin"] == nil)
        #expect(Self.message(Self.resolve("declare_goal", [
            "statement": .string("x"), "checkin": .string("daily"), "hour": .int(31)]))?.contains("`hour`") == true)
    }

    @Test func calendarEventUsesTheOwnersDayAndUnambiguousHour() throws {
        // Medido: el 3B mandaba 13:00 para "3 pm" y el miércoles para "el jueves".
        let (name, input) = try #require(Self.real(Self.resolve("add_calendar_event", [
            "title": .string("Reunión con Pedro"), "start": .string("2026-10-07 13:00"), "end": .string("2026-10-07 15:00")],
            owner: "agéndame reunión con Pedro el jueves a las 3 pm")))
        #expect(name == "calendar")
        #expect(input == .object([
            "action": .string("create"), "title": .string("Reunión con Pedro"),
            "start": .string("2026-10-08T15:00:00"), "end": .string("2026-10-08T16:00:00"),
        ]))
        // Sin end válido (o antes del inicio) ⇒ una hora.
        let (_, noEnd) = try #require(Self.real(Self.resolve("add_calendar_event", [
            "title": .string("x"), "start": .string("2026-10-09 10:00"), "end": .string("")])))
        #expect(noEnd["end"] == .string("2026-10-09T11:00:00"))
        let (_, withEnd) = try #require(Self.real(Self.resolve("add_calendar_event", [
            "title": .string("x"), "start": .string("2026-10-09 10:00"), "end": .string("2026-10-09 12:30")])))
        #expect(withEnd["end"] == .string("2026-10-09T12:30:00"))
    }

    @Test(arguments: [
        ("recuérdame mañana a las 9 llamar al banco", "2026-10-07 09:00", "2026-10-07T09:00:00"),
        ("a las 9 de la mañana del viernes", "2026-10-06 09:00", "2026-10-09T09:00:00"),
        ("hoy a las 8 de la noche", "2026-10-06 08:00", "2026-10-06T20:00:00"),
        ("pasado mañana 15:30", "2026-10-07 15:30", "2026-10-08T15:30:00"),
        ("el martes a las 7 am", "2026-10-06 07:00", "2026-10-13T07:00:00"),
        ("a las 3", "2026-10-07 15:00", "2026-10-07T15:00:00"),
        ("el 20 de octubre", "2026-10-20 10:00", "2026-10-20T09:00:00"),   // sin hora dicha: 9:00
    ])
    func ownerTextRepairsDayAndHour(owner: String, model: String, expected: String) throws {
        let (_, input) = try #require(Self.real(Self.resolve("remind_me", [
            "text": .string("x"), "when": .string(model), "repeat": .string("none")], owner: owner)))
        #expect(input["fire_at"] == .string(expected))
    }

    @Test func notesNeverOverwriteAndReadFallsBackToList() throws {
        let (name, write) = try #require(Self.real(Self.resolve("write_note", [
            "name": .string("compras"), "content": .string("leche y pan")])))
        #expect(name == "notes")
        #expect(write == .object(["action": .string("append"), "name": .string("compras"),
                                  "content": .string("leche y pan")]))
        let (_, unnamed) = try #require(Self.real(Self.resolve("write_note", ["content": .string("Comprar leche y pan")])))
        #expect(unnamed["name"] == .string("comprar-leche-y"))
        let (_, read) = try #require(Self.real(Self.resolve("read_note", ["name": .string("compras")])))
        #expect(read == .object(["action": .string("read"), "name": .string("compras")]))
        let (_, list) = try #require(Self.real(Self.resolve("read_note", ["name": .string(" ")])))
        #expect(list == .object(["action": .string("list")]))
        let (_, reminders) = try #require(Self.real(Self.resolve("list_reminders", [:])))
        #expect(reminders == .object(["action": .string("list")]))
        #expect(LocalToolAdapter.defaultNoteName("¡!") == "nota")
    }

    @Test func noteResultIsPresentedInFull() {
        let input: JSONValue = .object(["action": .string("append"), "name": .string("compras"),
                                        "content": .string("leche y pan")])
        let ok = LocalToolAdapter.present(ToolResult(content: "Anexado a 'compras'."), local: "write_note", input: input)
        #expect(ok.content == "Anotado en tu nota 'compras': leche y pan.")
        let failed = ToolResult(content: "Error", isError: true)
        #expect(LocalToolAdapter.present(failed, local: "write_note", input: input) == failed)
        let other = ToolResult(content: "Listo")
        #expect(LocalToolAdapter.present(other, local: "remind_me", input: input) == other)
    }

    @Test func numbersAsText() throws {
        #expect(Args(.object(["h": .string("8 pm")])).hour("h") == 20)
        #expect(Args(.object(["h": .double(7)])).hour("h") == 7)
        #expect(Args(.object(["h": .string("tarde")])).hour("h") == nil)
        #expect(Args(.object([:])).hour("h") == CheckInCadence.defaultHour)
        #expect(Args(.object(["t": .int(5)])).text("t") == "5")
        #expect(Args(.object(["t": .bool(true)])).text("t") == nil)
    }

    @Test func weekLineGivesTheLocalModelResolvedDates() {
        let line = WorkingMemory.weekLine(for: Self.now, timeZone: Self.bogota)
        #expect(line == "Fechas: hoy martes 2026-10-06, mañana miércoles 2026-10-07, jueves 2026-10-08, "
                + "viernes 2026-10-09, sábado 2026-10-10, domingo 2026-10-11, lunes 2026-10-12.")
    }

    @Test func onlyTheLocalProfileGetsTheWeekLine() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try store.startSession()
        for (profile, expected) in [(ContextProfile.onDevice, true), (.claude, false)] {
            let memory = WorkingMemory(store: store, profile: profile)
            await memory.updateClock(Self.now, timeZone: Self.bogota)
            let messages = try await memory.assemble(TurnInput(sessionId: sid, content: [.text("hola")]))
            let system = messages.filter { $0.role == .system }.map { OnDevicePromptBuilder.plainText($0.content) }
            #expect(system.contains { $0.contains("Fechas: hoy martes") } == expected)
        }
    }
}

@Suite struct OnDeviceSchemaGuidesTests {
    @Test func patternAndRangeTranslate() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "when": .object(["type": .string("string"), "pattern": .string(LocalToolAdapter.datePattern)]),
                "hour": .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(23)]),
                "bad": .object(["type": .string("integer"), "minimum": .int(5), "maximum": .int(1)]),
                "pick": .object(["type": .string("string"), "enum": .array([.string("a")]), "pattern": .string("x")]),
            ]),
            "required": .array([.string("when")]),
        ])
        guard case .object(_, _, let props) = OnDeviceSchema.from(jsonSchema: schema, name: "t") else {
            Issue.record("sin objeto"); return
        }
        let byName = Dictionary(uniqueKeysWithValues: props.map { ($0.name, $0) })
        #expect(byName["when"]?.schema == .patterned(description: nil, pattern: LocalToolAdapter.datePattern))
        #expect(byName["when"]?.isOptional == false)
        #expect(byName["hour"]?.schema == .bounded(description: nil, range: 0...23))
        #expect(byName["bad"]?.schema == .integer(description: nil))
        #expect(byName["pick"]?.schema == .string(description: nil, choices: ["a"]))
    }

    #if canImport(FoundationModels)
    @Test func localSetBridgesToGenerationSchemas() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        for tool in LocalToolAdapter.tools {
            guard case .client(let name, _, let schema) = tool.spec else { continue }
            _ = try OnDeviceSchemaBridge.generationSchema(for: OnDeviceSchema.from(jsonSchema: schema, name: name))
        }
        _ = try OnDeviceSchemaBridge.generationSchema(for: .object(name: "x", description: nil, properties: [
            .init(name: "p", description: nil, schema: .patterned(description: nil, pattern: "(["), isOptional: false),
        ]))
    }
    #endif
}

@Suite struct LocalNoteRepairTests {
    @Test func dictatedContentWinsWhenTheModelCopiesTheName() throws {
        let r = LocalToolAdapter.resolve(name: "write_note", input: .object([
            "name": .string("compras"), "content": .string("Compras")]), now: Date(), ownerText: "anota: comprar leche y pan")
        guard case .real(_, let input) = r else { Issue.record("debió traducir"); return }
        #expect(input["content"] == .string("comprar leche y pan"))
        let missing = LocalToolAdapter.resolve(name: "write_note", input: .object(["name": .string("x")]),
                                               now: Date(), ownerText: "Anótame que el wifi es casa123.")
        guard case .real(_, let wifi) = missing else { Issue.record("debió traducir"); return }
        #expect(wifi["content"] == .string("el wifi es casa123"))
        #expect(LocalToolAdapter.dictatedNote("¿qué notas tengo?") == nil)
        #expect(LocalToolAdapter.dictatedNote("apunta:   ") == nil)
        #expect(LocalToolAdapter.dictatedNote("toma nota de llamar a mamá") == "llamar a mamá")
    }

    @Test func confirmationAcceptance() {
        #expect(OnDevicePromptBuilder.acceptsConfirmation("Listo, quedó tu meta."))
        #expect(!OnDevicePromptBuilder.acceptsConfirmation("Listo, quedó tu meta de baj"))
        #expect(!OnDevicePromptBuilder.acceptsConfirmation(""))
        #expect(!OnDevicePromptBuilder.acceptsConfirmation(String(repeating: "a", count: 250) + "."))
    }
}

@Suite struct LocalOwnerIntentTests {
    static func resolve(_ name: String, _ input: [String: JSONValue], owner: String) -> JSONValue? {
        let r = LocalToolAdapter.resolve(name: name, input: .object(input), now: LocalToolAdapterTests.now,
                                         ownerText: owner, calendar: LocalToolAdapterTests.calendar)
        if case .real(_, let real) = r { return real }
        return nil
    }

    @Test(arguments: [
        ("recuérdame mañana a las 9 llamar al banco", "daily", "none"),
        ("recuérdame todos los días a las 9 tomar agua", "none", "daily"),
        ("recuérdame entre semana a las 9 el standup", "daily", "weekdays"),
        ("recuérdame cada lunes a las 9 la reunión", "none", "weekly"),
    ])
    func repetitionIsWhatTheOwnerSaid(owner: String, model: String, expected: String) throws {
        let input = try #require(Self.resolve("remind_me", [
            "text": .string("x"), "when": .string("2026-10-07 09:00"), "repeat": .string(model)], owner: owner))
        #expect(input["repeat"] == .string(expected))
    }

    @Test func aReminderRequestedAsAGoalIsRoutedToReminders() throws {
        let r = LocalToolAdapter.resolve(name: "declare_goal", input: .object([
            "statement": .string("tomar agua"), "checkin": .string("daily"), "hour": .int(8)]),
            now: LocalToolAdapterTests.now, ownerText: "recuérdame todos los días a las 8 tomar agua",
            calendar: LocalToolAdapterTests.calendar)
        guard case .real(let name, let input) = r else { Issue.record("debió traducir"); return }
        #expect(name == "anima_reminders")
        #expect(input["text"] == .string("tomar agua"))
        #expect(input["repeat"] == .string("daily"))
        #expect(input["fire_at"] == .string("2026-10-07T08:00:00"))   // hoy 8:00 ya pasó
        let once = try #require(Self.resolve("declare_goal", [
            "statement": .string("pagar la luz"), "checkin": .string("none"), "hour": .int(20)],
            owner: "recuérdame el viernes a las 5 pm pagar la luz"))
        #expect(once["fire_at"] == .string("2026-10-09T17:00:00"))
        #expect(once["repeat"] == .string("none"))
        let goal = try #require(Self.resolve("declare_goal", [
            "statement": .string("leer"), "checkin": .string("none"), "hour": .int(20)],
            owner: "mi meta es leer, recuérdame cada semana"))
        #expect(goal["action"] == .string("declare"))
        #expect(goal["checkin"]?["cadence"] == .string("weekly"))
    }

    @Test func listEventsReadsTheCalendar() throws {
        #expect(try #require(Self.resolve("list_events", ["days": .int(2)], owner: "¿qué tengo mañana?"))
                == .object(["action": .string("list"), "days_ahead": .int(2)]))
        #expect(try #require(Self.resolve("list_events", ["days": .string("90 días")], owner: ""))["days_ahead"] == .int(30))
        #expect(try #require(Self.resolve("list_events", [:], owner: ""))["days_ahead"] == .int(7))
        #expect(LocalToolAdapter.intended(name: "list_events", ownerText: "agéndame cita mañana") == "add_calendar_event")
    }

    @Test func listGoalsReadsGoals() throws {
        let input = try #require(Self.resolve("list_goals", [:], owner: "¿qué metas tengo?"))
        #expect(input == .object(["action": .string("list")]))
    }
}

@Suite struct LocalConfirmationGateTests {
    @Test func theAnswerMustNameWhatWasDoneOrRead() {
        #expect(OnDevicePromptBuilder.salientStems("llamar al banco") == ["llam", "banc"])
        let banco: [SalientGroup] = [.subject(["llam", "banc"]), SalientGroup(["recuerd", "record", "avis", "program"])]
        #expect(OnDevicePromptBuilder.acceptsConfirmation("Listo, te recuerdo llamar al banco.", salient: banco))
        #expect(OnDevicePromptBuilder.acceptsConfirmation("Listo, mañana a las 9 te recordaré llamar al banco.", salient: banco))
        #expect(!OnDevicePromptBuilder.acceptsConfirmation("El recordatorio está programado para mañana.", salient: banco))
        #expect(!OnDevicePromptBuilder.acceptsConfirmation("El dueño tiene que llamar al banco.", salient: banco))
        #expect(!OnDevicePromptBuilder.acceptsConfirmation("Hola [nombre], banco.", salient: banco))
        #expect(!OnDevicePromptBuilder.acceptsConfirmation("Listo, me acordé de llamar al banco.", salient: banco))
        #expect(OnDevicePromptBuilder.listedItems("Programados:\n- llamar al banco — mañana\n- pan")
                == ["llamar al banco", "pan"])
        #expect(OnDevicePromptBuilder.withoutListIds("- [9F2C-AB12-77] x") == "- x")
    }

    @Test func theRequestCarriesTheSalientWords() throws {
        let read = AssembledContext(messages: [
            .user("¿qué recordatorios tengo?"),
            .assistant([.toolUse(id: "t1", name: "list_reminders", input: .object([:]))]),
            .user([.toolResult(toolUseId: "t1", content: "Programados:\n- [AB-12-34-56] llamar al banco — mañana",
                               isError: false)]),
        ])
        let r = OnDevicePromptBuilder.request(ctx: read, tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(r.salientWords == [SalientGroup(["llam", "banc"])])
        #expect(r.fallbackText == "Programados:\n- llamar al banco — mañana")
        #expect(r.maxResponseTokens == OnDevicePromptBuilder.confirmationMaxTokens)
        let write = AssembledContext(messages: [
            .user("anota: pan"),
            .assistant([.toolUse(id: "t1", name: "write_note", input: .object(["name": .string("x"), "content": .string("comprar pan integral")]))]),
            .user([.toolResult(toolUseId: "t1", content: "ok", isError: false)]),
        ])
        #expect(OnDevicePromptBuilder.request(ctx: write, tools: [], opts: try OnDeviceTestConfig.opts()).salientWords
                == [.subject(["comp", "inte"]), SalientGroup(["anot", "nota", "guard", "apunt"])])
    }

    @Test func aReadAnswerThatDropsTheItemFallsBackToTheList() async throws {
        let ctx = AssembledContext(messages: [
            .user("¿qué recordatorios tengo?"),
            .assistant([.toolUse(id: "t1", name: "list_reminders", input: .object([:]))]),
            .user([.toolResult(toolUseId: "t1", content: "Programados:\n- llamar al banco — mañana", isError: false)]),
        ])
        let session = MockOnDeviceSession([[.snapshot("Tienes un recordatorio para mañana.")]])
        let provider = OnDeviceProvider(session: session, availability: { .available })
        let response = try await provider.completeCollecting(ctx, tools: [], opts: try OnDeviceTestConfig.opts())
        #expect(response.content == [.text("Programados:\n- llamar al banco — mañana")])
    }

    @Test func calendarAndGoalsArePresentedForTheLocalModel() {
        let event = LocalToolAdapter.present(ToolResult(content: "Evento 'x' creado (id 1)."), local: "add_calendar_event",
                                             input: .object(["title": .string("Reunión con Pedro"),
                                                             "start": .string("2026-10-08T15:00:00")]))
        #expect(event.content == "Evento 'Reunión con Pedro' agendado el jue 8 oct, 3:00 p. m.")
        let goals = LocalToolAdapter.present(ToolResult(content: "El dueño no tiene metas activas."), local: "list_goals",
                                             input: .object([:]))
        #expect(goals.content == "No tienes metas activas.")
        let missing = ToolResult(content: "x")
        #expect(LocalToolAdapter.present(missing, local: "add_calendar_event", input: .object([:])) == missing)
        #expect(LocalToolAdapter.present(missing, local: "write_note", input: .object([:])) == missing)
    }
}

@Suite struct LocalIntentRedirectTests {
    @Test(arguments: [
        ("list_reminders", "recuérdame mañana a las 9 llamar al banco", "remind_me"),
        ("list_goals", "recuérdame mañana a las 9 llamar al banco", "remind_me"),
        ("list_reminders", "agéndame reunión con Pedro el jueves", "add_calendar_event"),
        ("read_note", "anota: comprar leche", "write_note"),
        ("list_goals", "quiero leer 10 libros", "declare_goal"),
        ("list_reminders", "¿qué recordatorios tengo?", "list_reminders"),
        ("list_reminders", "qué recordatorios tengo", "list_reminders"),
        ("list_goals", "dime mis metas", "list_goals"),
        ("list_reminders", "", "list_reminders"),
        ("remind_me", "¿qué recordatorios tengo?", "remind_me"),
        ("list_reminders", "hola", "list_reminders"),
    ])
    func intendedTool(called: String, owner: String, expected: String) {
        #expect(LocalToolAdapter.intended(name: called, ownerText: owner) == expected)
    }

    @Test func aReadCallForACreationRequestIsAGuidedError() {
        let r = LocalToolAdapter.resolve(name: "list_reminders", input: .object([:]), now: Date(),
                                         ownerText: "recuérdame mañana a las 9 llamar al banco")
        #expect(r == .invalid(tool: "anima_reminders", message: "El dueño pidió crear algo, no consultar: usa remind_me."))
    }

}
