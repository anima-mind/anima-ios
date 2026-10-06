import Foundation
import GRDB
import Testing
@testable import AnimaKit

/// El modelo de Apple REAL con el set del `LocalToolAdapter` (opt-in
/// `ANIMA_FM_SMOKE=1`; Apple Intelligence encendido). Cada caso corre
/// `ANIMA_FM_RUNS` veces seguidas (default 3) y TODAS deben pasar. Registro
/// completo de la app (el adapter decide qué viaja), política de la app y un
/// dueño que aprueba (la agenda pide ok). Una fila por corrida:
/// `[fm-e2e] caso | corrida | tool → parámetros | ok/fallo | texto`.
@Suite(.serialized) struct LiveLocalModelSmokeTests {

    static var enabled: Bool {
        guard ProcessInfo.processInfo.environment["ANIMA_FM_SMOKE"] == "1" else { return false }
        guard OnDeviceAvailability.current().isAvailable else {
            print("[fm-e2e] modelo no disponible: \(OnDeviceAvailability.current().rawValue), skip"); return false
        }
        return true
    }

    static var runs: Int { Int(ProcessInfo.processInfo.environment["ANIMA_FM_RUNS"] ?? "") ?? 3 }

    struct Approve: ConfirmationProvider {
        func confirm(_ request: ConfirmationRequest) async -> Bool { true }
    }

    struct World {
        let store: SymbolicStore
        let queue: DatabaseQueue
        let reminders: AnimaReminderStore
        let other: OtherModel
        let calendar: MockCalendarStore
        let notesRoot: URL
        let loop: AgentLoop
        let sid: SessionID

        init(breakReminders: Bool = false) async throws {
            queue = try AnimaDatabase.temporary()
            store = SymbolicStore(queue: queue)
            reminders = AnimaReminderStore(queue: queue)
            other = OtherModel(queue: queue)
            calendar = MockCalendarStore()
            notesRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            if breakReminders {
                try await queue.write { try $0.execute(sql: "DROP TABLE anima_reminder") }
            }
            let calendar = self.calendar
            let tools: [any SensorimotorTool] = [
                CalendarTool(makeStore: { calendar }), RemindersTool(), NotesTool(root: notesRoot),
                PhoneContextTool(), CameraTool(), AudioTool(), GlassesShowTool(host: nil), GlassesCameraTool(host: nil),
                AnimaRemindersTool(store: reminders), GoalsTool(otherModel: other),
            ]
            loop = AgentLoop(provider: OnDeviceProvider.system(), store: store, telemetry: Telemetry(queue: queue),
                             router: try OnDeviceTestConfig.router(), authMode: .apiKey, token: "",
                             clientTools: tools, serverTools: [],
                             permissionPolicy: .app(ownerAllowlist: { [] }), confirmation: Approve(),
                             sleep: { _ in })
            sid = try store.startSession()
        }
    }

    struct Turn {
        var calls: [String] = []
        var okTools: [String] = []
        var failedTools: [String] = []
        var text = ""
        var notice: String?
        var budget: Int?
    }

    static func turn(_ world: World, _ prompt: String) async -> Turn {
        var t = Turn()
        for await event in await world.loop.run(sessionId: world.sid, userText: prompt) {
            switch event {
            case .assistantMessage(let blocks):
                for case .toolUse(_, let name, let input) in blocks {
                    t.calls.append("\(name) \(LoopDetector.canonical(input))")
                }
            case .toolFinished(let name, let isError):
                if isError { t.failedTools.append(name) } else { t.okTools.append(name) }
            case .textDelta(let d): t.text += d
            case .toolFailure(let n): t.notice = n
            case .context(let gauge): t.budget = gauge.budgetTokens
            default: break
            }
        }
        return t
    }

    static func row(_ name: String, _ run: Int, _ t: Turn, _ ok: Bool) {
        let calls = t.calls.isEmpty ? "(sin tool)" : t.calls.joined(separator: " ; ")
        let text = t.text.replacingOccurrences(of: "\n", with: " ")
        print("[fm-e2e] \(name) | \(run) | \(calls) | \(ok ? "ok" : "FALLO") | \(text)")
    }

    static var tomorrowAtNine: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
    }

    static func claimsSuccess(_ text: String) -> Bool {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        return ["listo", "he programado", "quedo", "te recuerdo", "programe", "creado"].contains { folded.contains($0) }
    }

    @Test func remindTomorrowAtNine() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "recuérdame mañana a las 9 llamar al banco")
            let created = await world.reminders.list()
            let ok = created.count == 1 && created.first?.fireAt == Self.tomorrowAtNine
                && created.first?.text.lowercased().contains("banco") == true && t.notice == nil
                && t.budget == ContextProfile.onDevice.contextBudgetTokens
            Self.row("1 recordatorio", run, t, ok)
            #expect(ok, "corrida \(run)")
        }
    }

    @Test func declareGoalWithWeeklyCheckIn() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "quiero bajar 5 kilos antes de diciembre, pregúntame cada semana cómo voy")
            let goals = await world.other.allGoals()
            let ok = goals.count == 1 && goals.first?.checkIn.cadence == .weekly
                && goals.first?.statement.lowercased().contains("kilos") == true && t.notice == nil
            Self.row("2 meta semanal", run, t, ok)
            #expect(ok, "corrida \(run)")
        }
    }

    @Test func scheduleMeetingOnThursday() async throws {
        guard Self.enabled else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var ahead = (5 - calendar.component(.weekday, from: today) + 7) % 7
        if ahead == 0 { ahead = 7 }
        let thursday = calendar.date(byAdding: .day, value: ahead, to: today)!
        let start = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: thursday)!
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "agéndame reunión con Pedro el jueves a las 3 pm")
            let events = world.calendar.created.value
            let ok = events.count == 1 && events.first?.1 == start
                && events.first?.0.lowercased().contains("pedro") == true && t.notice == nil
            Self.row("3 evento jueves", run, t, ok)
            #expect(ok, "corrida \(run)")
        }
    }

    @Test func writeANote() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            defer { try? FileManager.default.removeItem(at: world.notesRoot) }
            let t = await Self.turn(world, "anota: comprar leche y pan")
            let files = (try? FileManager.default.contentsOfDirectory(at: world.notesRoot, includingPropertiesForKeys: nil)) ?? []
            let content = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
            let ok = files.count == 1 && content.lowercased().contains("leche") && content.lowercased().contains("pan")
                && t.notice == nil
            Self.row("4 nota", run, t, ok)
            #expect(ok, "corrida \(run)")
        }
    }

    @Test func failingStoreNeverClaimsSuccess() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World(breakReminders: true)
            let t = await Self.turn(world, "recuérdame mañana a las 9 llamar al banco")
            let body = t.text.hasPrefix(ToolFailureNotice.marker)
                ? String(t.text.drop { $0 != "\n" }) : t.text
            let ok = t.text.hasPrefix("⚠️ No pude") && !Self.claimsSuccess(body) && !t.failedTools.isEmpty
            Self.row("5 store que lanza", run, t, ok)
            #expect(ok, "corrida \(run)")
        }
    }

    @Test func listsTheReminderItJustCreated() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            let first = await Self.turn(world, "recuérdame mañana a las 9 llamar al banco")
            let t = await Self.turn(world, "¿qué recordatorios tengo?")
            let created = await world.reminders.list()
            let ok = created.count == 1 && first.notice == nil && t.text.lowercased().contains("banco")
                && t.notice == nil
            Self.row("6 qué recordatorios", run, t, ok)
            #expect(ok, "corrida \(run)")
        }
    }

    // MARK: - Casos del review (fechas relativas al reloj real)

    static let calendar = Calendar.current
    static var today: Date { calendar.startOfDay(for: Date()) }
    static let monthNames = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
                             "septiembre", "octubre", "noviembre", "diciembre"]
    static let weekdayNames = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]

    static func at(_ day: Date, _ hour: Int) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    /// El próximo <weekday> (1=domingo), nunca hoy.
    static func next(_ weekday: Int) -> Date {
        var ahead = (weekday - calendar.component(.weekday, from: today) + 7) % 7
        if ahead == 0 { ahead = 7 }
        return calendar.date(byAdding: .day, value: ahead, to: today)!
    }

    /// Un recordatorio único con la prueba que se pide; imprime la fila.
    func expectReminder(_ name: String, _ prompt: String, at expected: Date, repeat cadence: ProactiveCadence = .none,
                        contains word: String, tolerance: TimeInterval = 0) async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, prompt)
            let created = await world.reminders.list()
            let first = created.first
            let onTime: Bool = first.map { abs($0.fireAt.timeIntervalSince(expected)) <= tolerance } ?? false
            let sameCadence: Bool = first?.repeatCadence == cadence
            let named: Bool = first.map { LocalWhen.fold($0.text).contains(LocalWhen.fold(word)) } ?? false
            let honest: Bool = t.notice == nil && !t.text.contains("ERROR")
            let ok = created.count == 1 && onTime && sameCadence && named && honest
            Self.row(name, run, t, ok)
            #expect(ok, "corrida \(run): \(created.map { ($0.text, $0.fireAt, $0.repeatCadence) })")
        }
    }

    @Test func fridayEveningTrash() async throws {
        try await expectReminder("7 viernes 7 pm basura", "recuérdame el viernes a las 7 de la noche sacar la basura",
                                 at: Self.at(Self.next(6), 19), contains: "basura")
    }

    @Test func weekdayPill() async throws {
        let tomorrow = Self.calendar.date(byAdding: .day, value: 1, to: Self.today)!
        var first = Self.at(Self.today, 8) > Date() ? Self.at(Self.today, 8) : Self.at(tomorrow, 8)
        while [1, 7].contains(Self.calendar.component(.weekday, from: first)) {
            first = Self.calendar.date(byAdding: .day, value: 1, to: first)!
        }
        try await expectReminder("11 laborales 8 am", "recuérdame todos los días laborales a las 8 tomar la pastilla",
                                 at: first, repeat: .weekdays, contains: "pastilla")
    }

    @Test func explicitDateBeatsTheWeekday() async throws {
        let day = Self.calendar.date(byAdding: .day, value: 9, to: Self.today)!
        let p = Self.calendar.dateComponents([.day, .month, .weekday], from: day)
        let prompt = "recuérdame el \(Self.weekdayNames[p.weekday! - 1]) \(p.day!) de \(Self.monthNames[p.month! - 1]) "
            + "a las 10 la cita con el médico"
        try await expectReminder("12 fecha explícita", prompt, at: Self.at(day, 10), contains: "médico")
    }

    @Test func inTwoHours() async throws {
        try await expectReminder("13 en 2 horas", "recuérdame en 2 horas revisar el horno",
                                 at: Date().addingTimeInterval(7200), contains: "horno", tolerance: 180)
    }

    @Test func dateWithMonth() async throws {
        let day = Self.calendar.date(byAdding: .day, value: 40, to: Self.today)!
        let p = Self.calendar.dateComponents([.day, .month], from: day)
        try await expectReminder("14 día de mes", "recuérdame el \(p.day!) de \(Self.monthNames[p.month! - 1]) a las 9 pagar el arriendo",
                                 at: Self.at(day, 9), contains: "arriendo")
    }

    @Test func dayAfterTomorrow() async throws {
        let day = Self.calendar.date(byAdding: .day, value: 2, to: Self.today)!
        try await expectReminder("15 pasado mañana", "recuérdame pasado mañana a las 10 llevar el carro al taller",
                                 at: Self.at(day, 10), contains: "carro")
    }

    @Test func todayBeatsTheDictatedTomorrow() async throws {
        let late = Self.calendar.component(.hour, from: Date()) >= 17
        let prompt = late ? "recuérdame hoy a las 11 de la noche que mañana es el examen"
                          : "recuérdame hoy a las 6 de la tarde que mañana es el examen"
        try await expectReminder("17 hoy que mañana", prompt, at: Self.at(Self.today, late ? 23 : 18), contains: "examen")
    }

    @Test func everyMonday() async throws {
        try await expectReminder("18 todos los lunes", "recuérdame todos los lunes a las 9 la reunión de equipo",
                                 at: Self.at(Self.next(2), 9), repeat: .weekly, contains: "reuni")
    }

    @Test func readingGoalEverySunday() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "quiero leer 12 libros este año, pregúntame cada domingo")
            let goals = await world.other.allGoals()
            let checkIn = goals.first?.checkIn
            let sunday: Bool = checkIn?.cadence == .weekly && checkIn?.weekday == 1
            let named: Bool = goals.first?.statement.lowercased().contains("libros") ?? false
            let honest: Bool = t.notice == nil && !t.text.lowercased().contains("lunes")
            let ok = goals.count == 1 && sunday && named && honest
            Self.row("8 meta cada domingo", run, t, ok)
            #expect(ok, "corrida \(run): \(goals.map { ($0.statement, $0.checkIn.phrase) })")
        }
    }

    @Test func officeWifiNote() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            defer { try? FileManager.default.removeItem(at: world.notesRoot) }
            let t = await Self.turn(world, "anota que la clave del wifi de la oficina es casa123")
            let files = (try? FileManager.default.contentsOfDirectory(at: world.notesRoot, includingPropertiesForKeys: nil)) ?? []
            let content = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
            let ok = files.count == 1 && content.contains("casa123") && t.notice == nil
            Self.row("9 nota wifi", run, t, ok)
            #expect(ok, "corrida \(run): \(files.map(\.lastPathComponent)) \(content)")
        }
    }

    @Test func whatGoalsDoIHave() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let empty = try await World()
            let none = await Self.turn(empty, "¿qué metas tengo?")
            let noneOK = await empty.other.allGoals().isEmpty && none.notice == nil
                && LocalWhen.fold(none.text).contains("no tienes") && !none.text.contains("ERROR")
            Self.row("10a qué metas (vacío)", run, none, noneOK)
            #expect(noneOK, "corrida \(run)")

            let seeded = try await World()
            let id = await seeded.other.ingestStated(statement: "correr una maratón",
                                                     desiredState: .progressCheckIn(everyDays: 8), evidence: "test")
            _ = await seeded.other.setCheckIn(id: id, CheckInCadence(cadence: .weekly, hour: 20, weekday: 1))
            let some = await Self.turn(seeded, "¿qué metas tengo?")
            let listed = some.text.split(separator: "\n").filter { $0.hasPrefix("- ") }.count
            let someOK = await seeded.other.allGoals().count == 1 && some.notice == nil
                && LocalWhen.fold(some.text).contains("marat") && !some.text.contains("stated") && listed == 1
            Self.row("10b qué metas (una)", run, some, someOK)
            #expect(someOK, "corrida \(run)")
        }
    }

    @Test func iWantToSeeMyGoalsNeverCreatesOne() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "quiero ver mis metas")
            let empty = await world.other.allGoals().isEmpty
            let listed = t.calls.contains { $0.hasPrefix("list_goals") } && !t.calls.contains { $0.hasPrefix("declare_goal") }
            let answered = ["no tienes", "no hay", "ningun"].contains(where: LocalWhen.fold(t.text).contains)
            let ok = empty && listed && answered && t.notice == nil
            Self.row("16 quiero ver mis metas", run, t, ok)
            #expect(ok, "corrida \(run)")
        }
    }

    // MARK: - Ronda 2 del review

    @Test func dayOfMonthWithMorningHour() async throws {
        let day = Self.calendar.date(byAdding: .day, value: 9, to: Self.today)!
        let p = Self.calendar.dateComponents([.day, .month], from: day)
        try await expectReminder("19 día de mes 10 de la mañana",
                                 "recuérdame el \(p.day!) de \(Self.monthNames[p.month! - 1]) a las 10 de la mañana la cita",
                                 at: Self.at(day, 10), contains: "cita")
    }

    @Test func eventRangeAfterDayOfMonth() async throws {
        guard Self.enabled else { return }
        let day = Self.calendar.date(byAdding: .day, value: 9, to: Self.today)!
        let p = Self.calendar.dateComponents([.day, .month], from: day)
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "agéndame dentista el \(p.day!) de \(Self.monthNames[p.month! - 1]) de 2 a 3 de la tarde")
            let events = world.calendar.created.value
            let ok = events.count == 1 && events.first?.1 == Self.at(day, 14) && events.first?.2 == Self.at(day, 15)
                && t.notice == nil
            Self.row("20 evento de 2 a 3", run, t, ok)
            #expect(ok, "corrida \(run): \(events.map { ($0.0, $0.1, $0.2) })")
        }
    }

    @Test func deletingAGoalNeverCreatesOne() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            _ = await world.other.ingestStated(statement: "correr 10 km", desiredState: .progressCheckIn(everyDays: 8),
                                               evidence: "test")
            let t = await Self.turn(world, "elimina mi meta de correr")
            let goals = await world.other.allGoals()
            let folded = LocalWhen.fold(t.text)
            let lies = ["elimine", "eliminad", "borre", "borrad", "quitad", "ya no esta", "listo"].contains(where: folded.contains)
            let ok = goals.count == 1 && !t.calls.contains { $0.hasPrefix("declare_goal") } && !lies
            Self.row("21 elimina mi meta", run, t, ok)
            #expect(ok, "corrida \(run): \(goals.map(\.statement))")
        }
    }

    @Test func withinTwentyMinutes() async throws {
        try await expectReminder("22 dentro de 20 min", "recuérdame dentro de 20 minutos sacar la ropa",
                                 at: Date().addingTimeInterval(1200), contains: "ropa", tolerance: 180)
    }

    @Test func inFortyFiveMinutes() async throws {
        try await expectReminder("23 en 45 min", "recuérdame en 45 minutos apagar el horno",
                                 at: Date().addingTimeInterval(2700), contains: "horno", tolerance: 180)
    }

    @Test func everyFifteenDaysIsOnceAndSaid() async throws {
        guard Self.enabled else { return }
        let expected = Self.at(Self.calendar.date(byAdding: .day, value: 15, to: Self.today)!, 9)
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "recuérdame cada 15 días revisar la tarjeta")
            let created = await world.reminders.list()
            let once: Bool = created.count == 1 && created.first?.repeatCadence == ProactiveCadence.none
            let onDate: Bool = created.first?.fireAt == expected
            let said: Bool = LocalWhen.fold(t.text).contains("repit")
            let ok = once && onDate && said && t.notice == nil
            Self.row("24 cada 15 días", run, t, ok)
            #expect(ok, "corrida \(run): \(created.map { ($0.fireAt, $0.repeatCadence) })")
        }
    }

    @Test func eventsThisWeekInLocalTime() async throws {
        guard Self.enabled else { return }
        let tomorrow = Self.calendar.date(byAdding: .day, value: 1, to: Self.today)!
        for run in 1...Self.runs {
            let world = try await World()
            world.calendar.records = [
                CalendarEventRecord(id: "EK-1:ABC", title: "Dentista", notes: nil, start: Self.at(tomorrow, 15)),
                CalendarEventRecord(id: "EK-2:DEF", title: "Almuerzo con Ana", notes: nil,
                                    start: Self.at(Self.calendar.date(byAdding: .day, value: 2, to: Self.today)!, 13)),
            ]
            let t = await Self.turn(world, "¿qué eventos tengo esta semana?")
            let folded = LocalWhen.fold(t.text)
            let ok = folded.contains("dentista") && !t.text.contains("EK-") && !t.text.contains("Z")
                && !t.text.contains("T15") && t.notice == nil
            Self.row("25 eventos de la semana", run, t, ok)
            #expect(ok, "corrida \(run)")
        }
    }

    @Test func noHourMeansAPlausibleHour() async throws {
        try await expectReminder("26 mañana sin hora", "recuérdame mañana que hoy fue un buen día",
                                 at: Self.at(Self.calendar.date(byAdding: .day, value: 1, to: Self.today)!, 9),
                                 contains: "buen")
    }

    @Test func howManyRemindersIsAQuery() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "quiero saber cuántos recordatorios tengo")
            let ok = await world.reminders.list().isEmpty && !t.calls.contains { $0.hasPrefix("remind_me") }
                && t.notice == nil && !t.text.contains("ERROR")
            Self.row("27 cuántos recordatorios", run, t, ok)
            #expect(ok, "corrida \(run)")
        }
    }

    // MARK: - Ronda 3 del review

    @Test func changeVerbsInsideACreation() async throws {
        try await expectReminder("28 cambiar el aceite", "recuérdame el viernes cambiar el aceite del carro",
                                 at: Self.at(Self.next(6), 9), contains: "aceite")
        try await expectReminder("29 cancelar Netflix", "recuérdame el viernes cancelar Netflix",
                                 at: Self.at(Self.next(6), 9), contains: "netflix")
        try await expectReminder("30 quitar la ropa", "recuérdame en 20 minutos quitar la ropa",
                                 at: Date().addingTimeInterval(1200), contains: "ropa", tolerance: 180)
    }

    @Test func everyMonthIsOnceAndSaid() async throws {
        guard Self.enabled else { return }
        let expected = Self.at(Self.calendar.date(byAdding: .month, value: 1, to: Self.today)!, 9)
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "recuérdame cada mes pagar el arriendo")
            let created = await world.reminders.list()
            let once: Bool = created.count == 1 && created.first?.repeatCadence == ProactiveCadence.none
            let ok = once && created.first?.fireAt == expected && LocalWhen.fold(t.text).contains("repit") && t.notice == nil
            Self.row("31 cada mes", run, t, ok)
            #expect(ok, "corrida \(run): \(created.map { ($0.fireAt, $0.repeatCadence) })")
        }
    }

    @Test func lunchFromTwelveToOne() async throws {
        guard Self.enabled else { return }
        let day = Self.calendar.date(byAdding: .day, value: 16, to: Self.today)!
        let p = Self.calendar.dateComponents([.day, .month], from: day)
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "agéndame almuerzo con Ana el \(p.day!) de \(Self.monthNames[p.month! - 1]) de 12 a 1")
            let events = world.calendar.created.value
            let ok = events.count == 1 && events.first?.1 == Self.at(day, 12) && events.first?.2 == Self.at(day, 13)
                && t.notice == nil
            Self.row("32 almuerzo de 12 a 1", run, t, ok)
            #expect(ok, "corrida \(run): \(events.map { ($0.0, $0.1, $0.2) })")
        }
    }

    @Test func achievedGoalSaysWhereToMarkIt() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            _ = await world.other.ingestStated(statement: "leer 12 libros", desiredState: .progressCheckIn(everyDays: 8),
                                               evidence: "test")
            let t = await Self.turn(world, "ya cumplí mi meta de leer")
            let goals = await world.other.allGoals()
            let ok = goals.count == 1 && LocalWhen.fold(t.text).contains("tab metas")
                && !t.calls.contains { $0.hasPrefix("declare_goal") }
            Self.row("33 ya cumplí mi meta", run, t, ok)
            #expect(ok, "corrida \(run)")
        }
    }

    // MARK: - Ronda 4 del review

    @Test func stopRemindingSaysWhere() async throws {
        guard Self.enabled else { return }
        let cases: [(String, String)] = [
            ("ya no quiero que me recuerdes lo del banco", "tab recordatorios"),
            ("deja de recordarme llamar al banco", "tab recordatorios"),
            ("no me recuerdes más lo del banco", "tab recordatorios"),
            ("elimina la cita de la agenda", "calendario"),
        ]
        for (index, (prompt, place)) in cases.enumerated() {
            for run in 1...Self.runs {
                let world = try await World()
                _ = try await world.reminders.create(text: "llamar al banco", fireAt: Date().addingTimeInterval(86_400))
                let t = await Self.turn(world, prompt)
                let ok = await world.reminders.list().count == 1 && LocalWhen.fold(t.text).contains(place)
                    && !t.calls.contains { $0.hasPrefix("remind_me") } && t.notice == nil
                Self.row("\(34 + index) \(prompt.prefix(28))", run, t, ok)
                #expect(ok, "\(prompt) corrida \(run)")
            }
        }
    }

    @Test func meetingTitleIsTheDictatedOne() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "agéndame reunión el lunes de 3 a 4")
            let events = world.calendar.created.value
            let title = events.first.map { LocalWhen.fold($0.0) } ?? ""
            let ok = events.count == 1 && title.contains("reunion") && !title.contains("equipo")
                && events.first?.1 == Self.at(Self.next(2), 15) && events.first?.2 == Self.at(Self.next(2), 16)
            Self.row("38 reunión de 3 a 4", run, t, ok)
            #expect(ok, "corrida \(run): \(events.map { ($0.0, $0.1, $0.2) })")
        }
    }

    @Test func aPassedHourTodayGoesToTomorrow() async throws {
        guard Self.enabled else { return }
        let hour = max(1, Self.calendar.component(.hour, from: Date()) - 1)
        let tomorrow = Self.calendar.date(byAdding: .day, value: 1, to: Self.today)!
        let spoken = hour > 12 ? "\(hour - 12) de la tarde" : "\(hour) de la mañana"
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "recuérdame hoy a las \(spoken) almorzar")
            let created = await world.reminders.list()
            let ok = created.count == 1 && created.first?.fireAt == Self.at(tomorrow, hour)
                && LocalWhen.fold(t.text).contains("pas") && t.notice == nil
            Self.row("39 hoy ya pasó", run, t, ok)
            #expect(ok, "corrida \(run): \(created.map(\.fireAt))")
        }
    }

    // MARK: - Ronda 5 del review

    @Test func whatIsPending() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            _ = try await world.reminders.create(text: "llamar al banco", fireAt: Date().addingTimeInterval(86_400))
            _ = await world.other.ingestStated(statement: "leer 12 libros", desiredState: .progressCheckIn(everyDays: 8),
                                               evidence: "test")
            world.calendar.records = [CalendarEventRecord(id: "EK:1", title: "Dentista", notes: nil,
                                                          start: Date().addingTimeInterval(3600))]
            let t = await Self.turn(world, "¿qué tengo pendiente?")
            let ok = t.text.contains("Recordatorios:") && t.text.contains("banco") && t.text.contains("Metas:")
                && t.text.contains("libros") && t.text.contains("Hoy en tu agenda:") && t.text.contains("Dentista")
            Self.row("40 qué tengo pendiente", run, t, ok)
            #expect(ok, "corrida \(run)")
        }
    }

    @Test func meetingWithPedroKeepsTheName() async throws {
        guard Self.enabled else { return }
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "agéndame reunión con Pedro el próximo martes a las 3 pm")
            let events = world.calendar.created.value
            let ok = events.count == 1 && events.first?.0.contains("Pedro") == true
                && events.first?.1 == Self.at(Self.next(3), 15)
            Self.row("41 reunión con Pedro", run, t, ok)
            #expect(ok, "corrida \(run): \(events.map { ($0.0, $0.1) })")
        }
    }

    // MARK: - Ronda 6 del review

    @Test func agendaQuestionsKeepTheirRange() async throws {
        guard Self.enabled else { return }
        let tomorrow = Self.calendar.date(byAdding: .day, value: 1, to: Self.today)!
        let friday = Self.next(6)
        let cases: [(String, Date, String)] = [
            ("¿qué tengo mañana?", tomorrow, "Dentista"),
            ("qué hay esta semana", tomorrow, "Dentista"),
            ("qué tengo el viernes", friday, "Fútbol"),
        ]
        for (index, (prompt, day, title)) in cases.enumerated() {
            for run in 1...Self.runs {
                let world = try await World()
                world.calendar.records = [CalendarEventRecord(id: "EK:1", title: title, notes: nil, start: Self.at(day, 15))]
                let t = await Self.turn(world, prompt)
                let ok = t.text.contains(title) && !t.text.contains("nada pendiente") && t.notice == nil
                Self.row("\(42 + index) \(prompt)", run, t, ok)
                #expect(ok, "\(prompt) corrida \(run)")
            }
        }
    }

    @Test func creationWithAQuestionWordStillCreates() async throws {
        guard Self.enabled else { return }
        let tomorrow = Self.calendar.date(byAdding: .day, value: 1, to: Self.today)!
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "recuérdame qué tengo que comprar mañana a las 6")
            let created = await world.reminders.list()
            let ok = created.count == 1 && created.first.map { Self.calendar.isDate($0.fireAt, inSameDayAs: tomorrow) } == true
                && !t.text.contains("nada pendiente")
            Self.row("45 recuérdame qué tengo que comprar", run, t, ok)
            #expect(ok, "corrida \(run): \(created.map(\.fireAt))")

            let notes = try await World()
            defer { try? FileManager.default.removeItem(at: notes.notesRoot) }
            let n = await Self.turn(notes, "anota qué hay en la nevera: leche y huevos")
            let files = (try? FileManager.default.contentsOfDirectory(at: notes.notesRoot, includingPropertiesForKeys: nil)) ?? []
            let content = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
            let noted = files.count == 1 && content.contains("leche") && !n.text.contains("nada pendiente")
            Self.row("46 anota qué hay en la nevera", run, n, noted)
            #expect(noted, "corrida \(run)")
        }
    }

    @Test func dinnerNextWeekFriday() async throws {
        guard Self.enabled else { return }
        let thisFriday = Self.next(6)
        let current = Self.calendar.component(.weekday, from: Self.today)
        // Viernes de la semana siguiente (semana lunes-domingo).
        let mondayOffset = (current + 5) % 7
        let nextMonday = Self.calendar.date(byAdding: .day, value: 7 - mondayOffset, to: Self.today)!
        let nextFriday = Self.calendar.date(byAdding: .day, value: 4, to: nextMonday)!
        for run in 1...Self.runs {
            let world = try await World()
            let t = await Self.turn(world, "agéndame cena con Laura la próxima semana el viernes a las 8 de la noche")
            let events = world.calendar.created.value
            let ok = events.count == 1 && events.first?.1 == Self.at(nextFriday, 20) && events.first?.1 != Self.at(thisFriday, 20)
                && t.text.hasPrefix("Listo, agendé «") && !LocalWhen.fold(t.text).contains("restaurante")
            Self.row("47 cena la próxima semana", run, t, ok)
            #expect(ok, "corrida \(run): \(events.map { ($0.0, $0.1) })")
        }
    }

    // MARK: - Ronda 7 del review

    @Test func pendingForTomorrow() async throws {
        guard Self.enabled else { return }
        let tomorrow = Self.calendar.date(byAdding: .day, value: 1, to: Self.today)!
        for run in 1...Self.runs {
            let world = try await World()
            world.calendar.records = [CalendarEventRecord(id: "EK:1", title: "Dentista", notes: nil, start: Self.at(tomorrow, 15))]
            let t = await Self.turn(world, "¿qué tengo pendiente para mañana?")
            let ok = t.text.contains("Dentista") && !t.text.contains("nada pendiente") && t.notice == nil
            Self.row("48 pendiente para mañana", run, t, ok)
            #expect(ok, "corrida \(run)")
        }
    }

    // MARK: - Ronda 8 del review

    @Test func ordinaryQuestionsAreAnsweredByTheModel() async throws {
        guard Self.enabled else { return }
        let prompts = ["¿qué tengo que hacer para sacar el pasaporte?", "¿qué es la metafísica?"]
        for (index, prompt) in prompts.enumerated() {
            for run in 1...Self.runs {
                let world = try await World()
                let t = await Self.turn(world, prompt)
                let folded = LocalWhen.fold(t.text)
                let ok = !folded.contains("no tienes nada pendiente") && !folded.contains("no tienes metas")
                    && !folded.contains("no tienes recordatorios") && t.text.count > 20 && t.notice == nil
                Self.row("\(49 + index) \(prompt.prefix(30))", run, t, ok)
                #expect(ok, "\(prompt) corrida \(run)")
            }
        }
    }
}
