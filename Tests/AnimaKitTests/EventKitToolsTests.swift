import Foundation
import Testing
@testable import AnimaKit

// MARK: - Dobles de store

struct StoreFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class MockCalendarStore: CalendarStore, @unchecked Sendable {
    var access: Result<Bool, StoreFailure> = .success(true)
    var records: [CalendarEventRecord] = []
    var createError: StoreFailure?
    var deleteError: StoreFailure?
    let queriedWindow = Locked<(Date, Date)?>(nil)
    let created = Locked<[(String, Date, Date)]>([])
    let deleted = Locked<[String]>([])

    func requestAccess() async throws -> Bool { try access.get() }
    func events(from start: Date, to end: Date) -> [CalendarEventRecord] {
        queriedWindow.mutate { $0 = (start, end) }
        return records
    }
    func createEvent(title: String, start: Date, end: Date) throws -> String? {
        if let createError { throw createError }
        created.mutate { $0.append((title, start, end)) }
        return "EV-1"
    }
    func deleteEvent(id: String) throws -> Bool {
        if let deleteError { throw deleteError }
        deleted.mutate { $0.append(id) }
        return records.contains { $0.id == id }
    }
}

final class MockRemindersStore: RemindersStore, @unchecked Sendable {
    var access: Result<Bool, StoreFailure> = .success(true)
    var pending: [ReminderRecord] = []
    var saveError: StoreFailure?
    let created = Locked<[(String, DateComponents?)]>([])
    let completed = Locked<[String]>([])

    func requestAccess() async throws -> Bool { try access.get() }
    func incompleteReminders() async -> [ReminderRecord] { pending }
    func createReminder(title: String, due: DateComponents?) throws -> String {
        if let saveError { throw saveError }
        created.mutate { $0.append((title, due)) }
        return "RM-1"
    }
    func completeReminder(id: String) throws -> Bool {
        if let saveError { throw saveError }
        completed.mutate { $0.append(id) }
        return pending.contains { $0.id == id }
    }
}

struct MockPhoneSources: PhoneContextSources {
    var location: LocationReading = .noFix
    var contacts: ContactsLookup = .found([])
    let healthDays = Locked<[Int]>([])
    func lastLocation() -> LocationReading { location }
    func searchContacts(name: String) async -> ContactsLookup { contacts }
    func healthSummary(days: Int) async -> ToolResult {
        healthDays.mutate { $0.append(days) }
        return ToolResult(content: "salud \(days)d")
    }
}

private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
private func input(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }

// MARK: - CalendarTool

@Suite struct CalendarToolTests {

    private func tool(_ store: MockCalendarStore) -> CalendarTool { CalendarTool(makeStore: { store }) }

    @Test func missingActionIsError() async {
        let result = await tool(MockCalendarStore()).execute(input([:]))
        #expect(result.isError)
        #expect(result.content.contains("falta 'action'"))
    }

    @Test func unavailablePlatformDegrades() async {
        let result = await CalendarTool(makeStore: { nil }).execute(input(["action": .string("list")]))
        #expect(result.isError)
        #expect(result.content.contains("no está disponible"))
    }

    @Test func accessDeniedAndAccessErrorAreReported() async {
        let denied = MockCalendarStore(); denied.access = .success(false)
        let r1 = await tool(denied).execute(input(["action": .string("list")]))
        #expect(r1.isError && r1.content.contains("no ha concedido"))

        let broken = MockCalendarStore(); broken.access = .failure(StoreFailure(message: "TCC"))
        let r2 = await tool(broken).execute(input(["action": .string("list")]))
        #expect(r2.isError && r2.content.contains("Sin acceso al calendario: TCC"))
    }

    @Test func listSortsFormatsAndUsesWindow() async throws {
        let store = MockCalendarStore()
        store.records = [
            CalendarEventRecord(id: "b", title: "Dentista", notes: nil, start: iso("2026-09-26T15:00:00Z")),
            CalendarEventRecord(id: nil, title: nil, notes: nil, start: iso("2026-09-25T09:00:00Z")),
        ]
        let now = iso("2026-09-24T12:00:00Z")
        let result = await CalendarActions.run(action: "list", input: input(["action": .string("list"), "days_ahead": .int(3)]),
                                               store: store, now: now)
        #expect(!result.isError)
        #expect(result.content == """
            - [?] (sin título) @ 2026-09-25T09:00:00Z
            - [b] Dentista @ 2026-09-26T15:00:00Z
            """)
        let window = try #require(store.queriedWindow.value)
        #expect(window.0 == now)
        #expect(window.1.timeIntervalSince(now) == 3 * 86_400)
    }

    @Test func listDefaultsToSevenDaysAndClampsNonPositive() async throws {
        let store = MockCalendarStore()
        let now = iso("2026-09-24T12:00:00Z")
        _ = await CalendarActions.run(action: "list", input: input(["days_ahead": .string("x")]), store: store, now: now)
        #expect(try #require(store.queriedWindow.value).1.timeIntervalSince(now) == 7 * 86_400)
        _ = await CalendarActions.run(action: "list", input: input(["days_ahead": .int(-5)]), store: store, now: now)
        #expect(try #require(store.queriedWindow.value).1.timeIntervalSince(now) == 86_400)
    }

    @Test func listEmptyAndCappedAtFifty() async {
        let empty = await CalendarActions.list(store: MockCalendarStore(), now: Date(), daysAhead: 7, query: nil)
        #expect(empty.content == "No hay eventos en el rango solicitado.")
        #expect(!empty.isError)

        let store = MockCalendarStore()
        let base = Date()
        store.records = (0..<60).map {
            CalendarEventRecord(id: "e\($0)", title: "t", notes: nil, start: base.addingTimeInterval(Double($0)))
        }
        let result = CalendarActions.list(store: store, now: base, daysAhead: 7, query: nil)
        #expect(result.content.split(separator: "\n").count == CalendarActions.maxListed)
    }

    @Test func searchMatchesTitleOrNotesCaseInsensitive() async throws {
        let store = MockCalendarStore()
        let now = Date()
        store.records = [
            CalendarEventRecord(id: "1", title: "Reunión La Haus", notes: nil, start: now.addingTimeInterval(10)),
            CalendarEventRecord(id: "2", title: "Gym", notes: "llevar toalla", start: now.addingTimeInterval(20)),
            CalendarEventRecord(id: "3", title: "Cena", notes: nil, start: now.addingTimeInterval(30)),
        ]
        let byTitle = await CalendarActions.run(action: "search", input: input(["query": .string("HAUS")]),
                                                store: store, now: now)
        #expect(byTitle.content.contains("[1]") && !byTitle.content.contains("[2]"))
        #expect(try #require(store.queriedWindow.value).1.timeIntervalSince(now) == 90 * 86_400)

        let byNotes = await CalendarActions.run(action: "search", input: input(["query": .string("toalla")]),
                                                store: store, now: now)
        #expect(byNotes.content.contains("[2]") && !byNotes.content.contains("[3]"))

        let none = await CalendarActions.run(action: "search", input: input(["query": .string("zzz")]),
                                             store: store, now: now)
        #expect(none.content == "No hay eventos en el rango solicitado.")
    }

    @Test func createValidatesAndDefaultsToOneHour() async throws {
        let store = MockCalendarStore()
        let t = tool(store)
        let noTitle = await t.execute(input(["action": .string("create"), "title": .string("")]))
        #expect(noTitle.isError && noTitle.content.contains("falta 'title'"))

        let badStart = await t.execute(input(["action": .string("create"), "title": .string("x"),
                                              "start": .string("mañana")]))
        #expect(badStart.isError && badStart.content.contains("'start' inválido"))

        let ok = await t.execute(input(["action": .string("create"), "title": .string("Demo"),
                                        "start": .string("2026-10-01T10:00:00Z")]))
        #expect(ok.content == "Evento 'Demo' creado (id EV-1).")
        let (title, start, end) = try #require(store.created.value.first)
        #expect(title == "Demo")
        #expect(end.timeIntervalSince(start) == 3600)

        _ = await t.execute(input(["action": .string("create"), "title": .string("Largo"),
                                   "start": .string("2026-10-01T10:00:00Z"), "end": .string("2026-10-01T13:00:00Z")]))
        #expect(store.created.value[1].2 == iso("2026-10-01T13:00:00Z"))
    }

    @Test func createSurfacesStoreError() async {
        let store = MockCalendarStore()
        store.createError = StoreFailure(message: "calendario de solo lectura")
        let result = CalendarActions.create(store: store, input: input(["title": .string("x"),
                                                                        "start": .string("2026-10-01T10:00:00Z")]))
        #expect(result.isError)
        #expect(result.content == "No se pudo crear el evento: calendario de solo lectura")
    }

    @Test func deleteHandlesMissingNotFoundSuccessAndError() async {
        let store = MockCalendarStore()
        store.records = [CalendarEventRecord(id: "E1", title: "x", notes: nil, start: Date())]
        #expect(CalendarActions.delete(store: store, eventId: nil).isError)
        #expect(CalendarActions.delete(store: store, eventId: "nope").content == "No se encontró el evento indicado.")
        #expect(CalendarActions.delete(store: store, eventId: "E1") == ToolResult(content: "Evento borrado."))

        store.deleteError = StoreFailure(message: "boom")
        let failed = CalendarActions.delete(store: store, eventId: "E1")
        #expect(failed.isError && failed.content == "No se pudo borrar el evento: boom")
    }

    @Test func unknownActionIsError() async {
        let result = await tool(MockCalendarStore()).execute(input(["action": .string("move")]))
        #expect(result.isError && result.content.contains("desconocida: move"))
    }

    @Test func confirmationSummaries() {
        let t = CalendarTool()
        #expect(t.confirmationSummary(for: input(["action": .string("create"), "title": .string("Demo"),
                                                  "start": .string("2026-10-01")])) == "Crear evento 'Demo' el 2026-10-01")
        #expect(t.confirmationSummary(for: input(["action": .string("create")])) == "Crear evento '(sin título)' el ?")
        #expect(t.confirmationSummary(for: input(["action": .string("delete"), "event_id": .string("E1")]))
                == "Borrar el evento E1")
        #expect(t.confirmationSummary(for: input(["action": .string("delete")])) == "Borrar el evento ?")
        #expect(t.confirmationSummary(for: input(["action": .string("list")])) == "calendar: list")
        #expect(t.operation(for: input([:])) == "default")
        #expect(t.kind(for: input(["action": .string("search")])) == .afferent)
        #expect(t.kind(for: input([:])) == .efferent)  // sin acción: fail-closed a eferente
    }
}

// MARK: - RemindersTool

@Suite struct RemindersToolTests {

    private func tool(_ store: MockRemindersStore) -> RemindersTool { RemindersTool(makeStore: { store }) }

    @Test func missingActionUnavailableAndDenied() async {
        #expect(await tool(MockRemindersStore()).execute(input([:])).isError)

        let unavailable = await RemindersTool(makeStore: { nil }).execute(input(["action": .string("list")]))
        #expect(unavailable.isError && unavailable.content.contains("no están disponibles"))

        let denied = MockRemindersStore(); denied.access = .success(false)
        let r1 = await tool(denied).execute(input(["action": .string("list")]))
        #expect(r1.isError && r1.content.contains("no ha concedido"))

        let broken = MockRemindersStore(); broken.access = .failure(StoreFailure(message: "TCC"))
        let r2 = await tool(broken).execute(input(["action": .string("list")]))
        #expect(r2.content == "Sin acceso a recordatorios: TCC")
    }

    @Test func listFormatsDueDatesAndEmpty() async {
        let store = MockRemindersStore()
        #expect(await tool(store).execute(input(["action": .string("list")])).content == "No hay recordatorios pendientes.")

        store.pending = [
            ReminderRecord(id: "R1", title: "Pagar luz", due: iso("2026-09-30T17:00:00Z")),
            ReminderRecord(id: "R2", title: nil, due: nil),
        ]
        let result = await tool(store).execute(input(["action": .string("list")]))
        #expect(result.content == """
            - [R1] Pagar luz (vence 2026-09-30T17:00:00Z)
            - [R2] (sin título)
            """)
    }

    @Test func listCapsAtFifty() async {
        let store = MockRemindersStore()
        store.pending = (0..<70).map { ReminderRecord(id: "r\($0)", title: "t", due: nil) }
        let result = await RemindersActions.list(store: store)
        #expect(result.content.split(separator: "\n").count == RemindersActions.maxListed)
    }

    @Test func createWithAndWithoutDue() async throws {
        let store = MockRemindersStore()
        let t = tool(store)
        let noTitle = await t.execute(input(["action": .string("create")]))
        #expect(noTitle.isError && noTitle.content.contains("falta 'title'"))

        let ok = await t.execute(input(["action": .string("create"), "title": .string("Llamar"),
                                        "due": .string("2026-10-02T08:30:00Z")]))
        #expect(ok.content == "Recordatorio 'Llamar' creado (id RM-1).")
        let due = try #require(store.created.value.first?.1)
        #expect(due.minute == 30)
        #expect(due.second == nil)  // precisión a minuto

        _ = await t.execute(input(["action": .string("create"), "title": .string("Sin fecha"), "due": .string("pronto")]))
        #expect(store.created.value[1].1 == nil)  // fecha inválida → sin vencimiento
    }

    @Test func dueComponentsUsesGivenCalendar() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = try #require(RemindersActions.dueComponents("2026-10-02T08:30:00Z", calendar: utc))
        #expect([c.year, c.month, c.day, c.hour, c.minute] == [2026, 10, 2, 8, 30])
        #expect(RemindersActions.dueComponents(nil) == nil)
    }

    @Test func createAndCompleteSurfaceErrors() async {
        let store = MockRemindersStore()
        store.saveError = StoreFailure(message: "iCloud caído")
        let c = RemindersActions.create(store: store, input: input(["title": .string("x")]))
        #expect(c.content == "No se pudo crear el recordatorio: iCloud caído")
        let u = RemindersActions.complete(store: store, reminderId: "R1")
        #expect(u.content == "No se pudo actualizar el recordatorio: iCloud caído")
    }

    @Test func completeFoundNotFoundAndMissingId() async {
        let store = MockRemindersStore()
        store.pending = [ReminderRecord(id: "R1", title: "x", due: nil)]
        let t = tool(store)
        let ok = await t.execute(input(["action": .string("complete"), "reminder_id": .string("R1")]))
        #expect(ok == ToolResult(content: "Recordatorio marcado como completado."))
        let missing = await t.execute(input(["action": .string("complete"), "reminder_id": .string("R9")]))
        #expect(missing.isError)
        let noId = await t.execute(input(["action": .string("complete")]))
        #expect(noId.content == "No se encontró el recordatorio indicado.")
        #expect(store.completed.value == ["R1", "R9"])
    }

    @Test func unknownActionAndSummaries() async {
        let r = await tool(MockRemindersStore()).execute(input(["action": .string("snooze")]))
        #expect(r.isError && r.content.contains("desconocida: snooze"))

        let t = RemindersTool()
        #expect(t.confirmationSummary(for: input(["action": .string("create"), "title": .string("A"),
                                                  "due": .string("2026-10-02")])) == "Crear recordatorio 'A' (vence 2026-10-02)")
        #expect(t.confirmationSummary(for: input(["action": .string("create")])) == "Crear recordatorio '(sin título)'")
        #expect(t.confirmationSummary(for: input(["action": .string("complete"), "reminder_id": .string("R1")]))
                == "Marcar como completado el recordatorio R1")
        #expect(t.confirmationSummary(for: input(["action": .string("complete")]))
                == "Marcar como completado el recordatorio ?")
        #expect(t.confirmationSummary(for: input(["action": .string("list")])) == "reminders: list")
        #expect(t.operation(for: input([:])) == "default")
        #expect(t.kind(for: input(["action": .string("list")])) == .afferent)
        #expect(t.kind(for: input(["action": .string("complete")])) == .efferent)
    }
}

// MARK: - PhoneContextTool

@Suite struct PhoneContextToolTests {

    @Test func missingAndUnknownAction() async {
        let t = PhoneContextTool(sources: MockPhoneSources())
        #expect(await t.execute(input([:])).isError)
        let r = await t.execute(input(["action": .string("battery")]))
        #expect(r.isError && r.content.contains("desconocida: battery"))
        #expect(t.kind(for: input(["action": .string("contacts")])) == .afferent)
        #expect(t.operation(for: input([:])) == "default")
    }

    @Test func locationReadingsMapToResults() async {
        func run(_ reading: LocationReading) async -> ToolResult {
            await PhoneContextTool(sources: MockPhoneSources(location: reading)).execute(input(["action": .string("location")]))
        }
        let fix = await run(.fix(latitude: 4.609_710_12, longitude: -74.081_749, accuracy: 12.4))
        #expect(fix == ToolResult(content: "Última ubicación conocida: 4.60971, -74.08175 (±12m)."))
        let noFix = await run(.noFix)
        #expect(!noFix.isError && noFix.content.contains("No hay una ubicación reciente"))
        #expect(await run(.denied).isError)
        let unavailable = await run(.unavailable)
        #expect(unavailable.isError && unavailable.content.contains("no está disponible"))
    }

    @Test func contactsRequireName() async {
        let t = PhoneContextTool(sources: MockPhoneSources())
        let r = await t.execute(input(["action": .string("contacts"), "name": .string("")]))
        #expect(r.isError && r.content.contains("falta 'name'"))
    }

    @Test func contactsLookupsMapToResults() async {
        func run(_ lookup: ContactsLookup) async -> ToolResult {
            await PhoneContextTool(sources: MockPhoneSources(contacts: lookup))
                .execute(input(["action": .string("contacts"), "name": .string("Ana")]))
        }
        let found = await run(.found([
            ContactRecord(givenName: "Ana", familyName: "Pérez", phones: ["+57 300", "+57 301"]),
            ContactRecord(givenName: "Ana", familyName: "", phones: []),
        ]))
        #expect(found.content == "- Ana Pérez: +57 300, +57 301\n- Ana")
        #expect(await run(.found([])).content == "No se encontraron contactos que coincidan con 'Ana'.")
        #expect(await run(.denied).isError)
        #expect(await run(.failed("CNError 100")).content == "Error al buscar contactos: CNError 100")
        #expect(await run(.unavailable).content.contains("no están disponibles"))

        let many = (0..<30).map { ContactRecord(givenName: "A\($0)", familyName: "", phones: []) }
        #expect(PhoneContextFormat.contacts(.found(many), name: "A").content.split(separator: "\n").count == 20)
    }

    @Test func healthDaysDefaultAndClamp() async {
        let sources = MockPhoneSources()
        let t = PhoneContextTool(sources: sources)
        _ = await t.execute(input(["action": .string("health")]))
        _ = await t.execute(input(["action": .string("health"), "days": .int(0)]))
        let r = await t.execute(input(["action": .string("health"), "days": .int(30)]))
        #expect(r.content == "salud 30d")
        #expect(sources.healthDays.value == [7, 1, 30])
    }

    @Test func systemHealthOffIPhoneIsHonestStub() async {
        #if !os(iOS)
        let r = await SystemPhoneContextSources().healthSummary(days: 7)
        #expect(!r.isError)
        #expect(r.content.contains("solo está disponible en el iPhone"))
        #endif
    }
}
