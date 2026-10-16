import Foundation
import GRDB
import Testing
@testable import AnimaKit

// "seria bueno q el agente me haga como notificaciones cada dos 3 dias sin uso
// como preguntandome cosas, como estoy temas asi q me lleven mas a hablar con el AI"

enum NudgeFixtures {
    static let cal = ProactiveFixtures.calendar
    static func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { ProactiveFixtures.date(2026, 10, d, h, m) }
    static func defaults() -> UserDefaults { UserDefaults(suiteName: "nudge-tests-\(UUID().uuidString)")! }
    static var planner: ReengagementPlanner { ReengagementPlanner(calendar: cal) }

    static func reminder(_ id: String, at date: Date) -> LocalNotificationRequest {
        LocalNotificationRequest(id: "anima-reminder-\(id)", title: "Lumen", body: "x", trigger: .at(date),
                                 categoryId: ProactiveNotificationIDs.reminderCategory, deepLink: nil)
    }

    static func dailyCheckIn(_ hour: Int, weekday: Int? = nil) -> LocalNotificationRequest {
        var c = DateComponents()
        c.hour = hour
        c.minute = 0
        c.weekday = weekday
        return LocalNotificationRequest(id: "anima-checkin-g\(hour)", title: "Lumen", body: "x",
                                        trigger: .calendar(c, repeats: true),
                                        categoryId: ProactiveNotificationIDs.checkInCategory, deepLink: nil)
    }

    struct World {
        let queue: DatabaseQueue
        let clock: Locked<Date>
        let preference: ReengagementPreference
        let questions: ReengagementQuestionStore
        let engine: ReengagementEngine
        let fake: FakeNotificationScheduler
        let reminders: AnimaReminderStore
        let other: OtherModel
        let symbolic: SymbolicStore
        let scheduler: ProactiveScheduler
        let reconciler: ProactiveReconciler

        func set(_ date: Date) { clock.mutate { $0 = date } }
        func fires() -> [Date] {
            fake.scheduled.values.filter { ReengagementIDs.isChain($0.id) }.compactMap {
                if case .at(let d) = $0.trigger { return d } else { return nil }
            }.sorted()
        }
        func chain() -> [LocalNotificationRequest] {
            fake.scheduled.values.filter { ReengagementIDs.isChain($0.id) }.sorted { $0.id < $1.id }
        }
    }

    static func world(status: NotificationAuthorization = .granted, start: Date = at(5, 15, 10),
                      pulses: Int = 0) throws -> World {
        let queue = try AnimaDatabase.temporary()
        let clock = Locked(start)
        let now: @Sendable () -> Date = { clock.value }
        let preference = ReengagementPreference(defaults: defaults())
        let questions = ReengagementQuestionStore(queue: queue, now: now)
        let engine = ReengagementEngine(preference: preference, questions: questions, planner: planner,
                                        pulsesToday: { pulses }, now: now)
        let fake = FakeNotificationScheduler(status: status)
        let reminders = AnimaReminderStore(queue: queue, calendar: cal, now: now)
        let other = OtherModel(queue: queue, calendar: cal, now: now)
        let symbolic = SymbolicStore(queue: queue)
        let scheduler = ProactiveScheduler(scheduler: fake, reminders: reminders, otherModel: other,
                                           selfName: { "Lumen" }, calendar: cal, reengagement: engine)
        let reconciler = ProactiveReconciler(reminders: reminders, otherModel: other, store: symbolic, calendar: cal,
                                             now: now, reengagement: engine)
        return World(queue: queue, clock: clock, preference: preference, questions: questions, engine: engine,
                     fake: fake, reminders: reminders, other: other, symbolic: symbolic, scheduler: scheduler,
                     reconciler: reconciler)
    }
}

// MARK: - El planificador (puro)

@Suite struct ReengagementPlannerTests {
    typealias N = NudgeFixtures

    @Test func backoffDuplicaCadaDosIgnoradosHastaElTope() {
        let p = N.planner
        #expect((0..<8).map { p.gapDays(base: 3, index: $0) } == [3, 3, 6, 6, 12, 12, 14, 14])
        #expect((0..<6).map { p.gapDays(base: 5, index: $0) } == [5, 5, 10, 10, 14, 14])
        #expect((0..<7).map { p.gapDays(base: 2, index: $0) } == [2, 2, 4, 4, 8, 8, 14])
        #expect(p.gapDays(base: 3, index: 60) == 14)
    }

    @Test func horaPreferidaSiempreDentroDeLaVentanaDiurna() {
        let p = N.planner
        #expect(p.preferredTime(lastUse: N.at(5, 15, 10)) == (15, 0))
        #expect(p.preferredTime(lastUse: N.at(5, 15, 45)) == (15, 30))
        #expect(p.preferredTime(lastUse: N.at(5, 23, 40)) == (20, 0))
        #expect(p.preferredTime(lastUse: N.at(5, 2, 0)) == (10, 0))
        #expect(p.preferredTime(lastUse: N.at(5, 7, 30)) == (10, 0))
        #expect(p.preferredTime(lastUse: N.at(5, 20, 0)) == (20, 0))
    }

    @Test func cadenaDesdeElUltimoUsoConBackoff() {
        let chain = N.planner.chain(lastUse: N.at(5, 15, 10), days: 3, others: [], now: N.at(5, 15, 10))
        #expect(chain == [N.at(8, 15), N.at(11, 15), N.at(17, 15), N.at(23, 15)])
        // Control negativo: sin back-off los avisos serían cada 3 días parejos.
        let flat = [N.at(8, 15), N.at(11, 15), N.at(14, 15), N.at(17, 15)]
        #expect(chain != flat)
    }

    @Test func usoDeNocheAvisaDeDiaNuncaDeNoche() {
        let night = N.planner.chain(lastUse: N.at(5, 23, 50), days: 2, others: [], now: N.at(5, 23, 50))
        #expect(night.first == N.at(7, 20))
        let dawn = N.planner.chain(lastUse: N.at(5, 3, 0), days: 2, others: [], now: N.at(5, 3, 0))
        #expect(dawn.first == N.at(7, 10))
        for fire in night + dawn {
            let hour = N.cal.component(.hour, from: fire)
            #expect((10...20).contains(hour))
        }
    }

    @Test func losAvisosPasadosCuentanComoIgnorados() {
        // Cuatro días después del último uso: el del día 8 ya salió (ignorado) y
        // la cadena sigue con su back-off, no vuelve a empezar.
        let chain = N.planner.chain(lastUse: N.at(5, 15, 10), days: 3, others: [], now: N.at(9, 9))
        #expect(chain == [N.at(11, 15), N.at(17, 15), N.at(23, 15), ProactiveFixtures.date(2026, 11, 4, 15)])
    }

    @Test func esquivaUnRecordatorioCercaElMismoDia() {
        let others = [N.reminder("r", at: N.at(8, 15, 30))]
        let fire = try! #require(N.planner.chain(lastUse: N.at(5, 15, 10), days: 3, others: others,
                                                 now: N.at(5, 15, 10)).first)
        #expect(N.cal.isDate(fire, inSameDayAs: N.at(8, 12)))
        #expect(abs(fire.timeIntervalSince(N.at(8, 15, 30))) >= 3 * 3600)
        #expect(fire == N.at(8, 12, 30))
        // Control negativo: sin el recordatorio iría a la hora preferida.
        #expect(N.planner.chain(lastUse: N.at(5, 15, 10), days: 3, others: [], now: N.at(5, 15, 10)).first
                == N.at(8, 15))
    }

    @Test func esquivaUnCheckInDiarioALaMismaHora() {
        let fire = N.planner.chain(lastUse: N.at(5, 15, 10), days: 3, others: [N.dailyCheckIn(15)],
                                   now: N.at(5, 15, 10)).first
        #expect(fire == N.at(8, 18))
        // Un check-in semanal de otro día no estorba.
        let monday = N.planner.chain(lastUse: N.at(5, 15, 10), days: 3, others: [N.dailyCheckIn(15, weekday: 2)],
                                     now: N.at(5, 15, 10)).first
        #expect(monday == N.at(8, 15))
    }

    @Test func compartenElTopeDiario() {
        // El día 8 ya tiene 4 avisos de Anima: el de inactividad pasa al 9.
        let busy = (0..<4).map { N.reminder("r\($0)", at: N.at(8, 10 + $0 * 3)) }
        let fire = N.planner.chain(lastUse: N.at(5, 15, 10), days: 3, others: busy, now: N.at(5, 15, 10)).first
        #expect(fire == N.at(9, 15))
        // El pulso del deseo entregado ese día también cuenta.
        let loaded = N.planner.chain(lastUse: N.at(5, 15, 10), days: 3, others: Array(busy.prefix(1)),
                                     now: N.at(5, 15, 10),
                                     load: { N.cal.isDate($0, inSameDayAs: N.at(8, 12)) ? 3 : 0 }).first
        #expect(loaded == N.at(9, 15))
    }

    @Test func diaSinHuecosCaeTresDiasDespues() {
        var p = N.planner
        p.dailyCap = 0
        let fire = p.chain(lastUse: N.at(5, 15, 10), days: 3, others: [], now: N.at(5, 15, 10)).first
        #expect(fire == N.at(11, 15))
    }

    @Test func ocurrenciasPorTipoDeTrigger() {
        let day = N.at(8, 0)
        typealias P = ReengagementPlanner
        #expect(P.occurrences(of: N.reminder("a", at: N.at(8, 9)), on: day, calendar: N.cal) == [N.at(8, 9)])
        #expect(P.occurrences(of: N.reminder("a", at: N.at(9, 9)), on: day, calendar: N.cal).isEmpty)
        let immediate = LocalNotificationRequest(id: "i", title: "", body: "", trigger: .immediate, categoryId: "",
                                                 deepLink: nil)
        #expect(P.occurrences(of: immediate, on: day, calendar: N.cal).isEmpty)
        var monthly = DateComponents()
        monthly.day = 9
        monthly.hour = 8
        let request = LocalNotificationRequest(id: "m", title: "", body: "", trigger: .calendar(monthly, repeats: true),
                                               categoryId: "", deepLink: nil)
        #expect(P.occurrences(of: request, on: day, calendar: N.cal).isEmpty)
        #expect(P.occurrences(of: request, on: N.at(9, 0), calendar: N.cal) == [N.at(9, 8)])
    }
}

// MARK: - El motor: preguntas, entrega, back-off y reset

@Suite struct ReengagementEngineTests {
    typealias N = NudgeFixtures

    @Test func preferenciaPorDefectoCadaTresDias() {
        let pref = ReengagementPreference(defaults: N.defaults())
        #expect(pref.isEnabled && pref.days == 3 && pref.lastUseAt == nil)
        pref.days = 5
        #expect(pref.days == 5)
        pref.days = 4
        #expect(pref.days == 3)
        let raw = N.defaults()
        raw.set(9, forKey: ReengagementPreference.daysKey)
        #expect(ReengagementPreference(defaults: raw).days == 3)
    }

    @Test func usaLasPreguntasDelSuenoYLuegoLasDeRespaldo() async throws {
        let w = try N.world()
        try w.questions.replace(with: ["¿Cómo te fue en la reunión con Pedro?", "¿Seguiste con lo del gym?"], cycle: 4)
        await w.engine.recordUse()
        let requests = await w.engine.requests(others: [], title: "Lumen")
        #expect(requests.map(\.id) == ["anima-nudge-0", "anima-nudge-1", "anima-nudge-2", "anima-nudge-3"])
        #expect(requests.map(\.body).prefix(2) == ["¿Cómo te fue en la reunión con Pedro?", "¿Seguiste con lo del gym?"])
        #expect(requests[2].body == ReengagementFallback.questions[0])
        #expect(requests[3].body == ReengagementFallback.questions[1])
        #expect(requests.allSatisfy { $0.title == "Lumen" && $0.categoryId == ReengagementIDs.category })
        let link = try #require(requests[0].deepLink)
        guard case .nudge(let ref)? = AnimaDeepLink.parse(link) else { Issue.record("deep link"); return }
        #expect(w.questions.question(id: ref)?.text == requests[0].body)
        #expect(requests[0].trigger == .at(N.at(8, 15)))
    }

    @Test func cadaUsoReprogramaYResetea() async throws {
        let w = try N.world()
        await w.engine.recordUse()
        #expect(await w.engine.requests(others: [], title: "L").first?.trigger == .at(N.at(8, 15)))
        // Habló el 7 a las 9:40 → el aviso se va al 10 a las 10:00 (no queda el del 8).
        w.set(N.at(7, 9, 40))
        await w.engine.recordUse()
        let moved = await w.engine.requests(others: [], title: "L")
        #expect(moved.first?.trigger == .at(N.at(10, 10)))
        #expect(!moved.contains { $0.trigger == .at(N.at(8, 15)) })
    }

    @Test func dosIgnoradosDuplicanElIntervaloYUsarloLoResetea() async throws {
        let w = try N.world()
        await w.engine.recordUse()
        _ = await w.engine.requests(others: [], title: "L")
        // Pasan los avisos del 8 y del 11 sin que abra la app.
        w.set(N.at(12, 18))
        let after = await w.engine.requests(others: [], title: "L")
        #expect(after.first?.trigger == .at(N.at(17, 15)))   // 6 días: el doble
        // Vuelve a hablar: la cadena arranca otra vez cada 3 días.
        await w.engine.recordUse()
        let reset = await w.engine.requests(others: [], title: "L")
        #expect(reset.first?.trigger == .at(N.at(15, 18)))
        #expect(reset[1].trigger == .at(N.at(18, 18)))
    }

    @Test func unaPreguntaEntregadaNoSeRepite() async throws {
        let w = try N.world()
        let saved = try w.questions.replace(with: ["¿Cómo te fue en la reunión con Pedro?",
                                                   "¿Seguiste con lo del gym?"], cycle: 4)
        await w.engine.recordUse()
        _ = await w.engine.requests(others: [], title: "L")
        w.set(N.at(8, 16))
        let next = await w.engine.requests(others: [], title: "L")
        #expect(next.first?.body == "¿Seguiste con lo del gym?")
        #expect(w.questions.question(id: saved[0].id)?.deliveredAt == N.at(8, 15))
        #expect(!next.contains { $0.body == "¿Cómo te fue en la reunión con Pedro?" })
    }

    @Test func lasDeRespaldoRotanSinRepetirSeguido() async throws {
        let w = try N.world()
        await w.engine.recordUse()
        var bodies: [String] = []
        for _ in 0..<6 {
            let requests = await w.engine.requests(others: [], title: "L")
            let first = try #require(requests.first)
            bodies.append(first.body)
            guard case .at(let fire) = first.trigger else { Issue.record("trigger"); return }
            w.set(fire.addingTimeInterval(60))
        }
        #expect(Set(bodies).count == bodies.count)
        #expect(bodies.allSatisfy { ReengagementFallback.questions.contains($0) })
        #expect(bodies.allSatisfy(ReengagementTextGuard.isAllowed))
    }

    @Test func apagadoNoProgramaNada() async throws {
        let w = try N.world()
        w.preference.isEnabled = false
        #expect(await w.engine.requests(others: [], title: "L").isEmpty)
        w.preference.isEnabled = true
        w.preference.days = 5
        #expect(await w.engine.requests(others: [], title: "L").first?.trigger == .at(N.at(10, 15)))
    }

    @Test func tapAbreLaPreguntaYCuentaComoUso() async throws {
        let w = try N.world()
        let saved = try w.questions.replace(with: ["¿Cómo te fue en la reunión con Pedro?"], cycle: 4)
        await w.engine.recordUse()
        _ = await w.engine.requests(others: [], title: "L")
        w.set(N.at(8, 15, 2))
        let opened = try #require(await w.engine.open(ref: saved[0].id))
        #expect(opened.delivery.text == "¿Cómo te fue en la reunión con Pedro?" && !opened.alreadyShown)
        #expect(await w.engine.lastUseAt == N.at(8, 15, 2))
        #expect(await w.engine.open(ref: saved[0].id)?.alreadyShown == true)
        #expect(await w.engine.open(ref: "nope") == nil)
        #expect(await w.engine.open(ref: "fallback-2")?.delivery.text == ReengagementFallback.questions[2])
    }

    @Test func entregadoSinRespuestaApareceAlAbrirSoloUnaVez() async throws {
        let w = try N.world()
        await w.engine.recordUse()
        _ = await w.engine.requests(others: [], title: "L")
        w.set(N.at(8, 20))
        let unseen = await w.engine.unseenRecent()
        #expect(unseen.map(\.text) == [ReengagementFallback.questions[0]])
        #expect(await w.engine.unseenRecent().isEmpty)
        // Más de 12 h después ya no se pinta.
        let late = try N.world()
        await late.engine.recordUse()
        _ = await late.engine.requests(others: [], title: "L")
        late.set(N.at(9, 9))
        #expect(await late.engine.unseenRecent().isEmpty)
    }

    @Test func probarEnUnMinutoUsaLaProximaPregunta() async throws {
        let w = try N.world()
        try w.questions.replace(with: ["¿Seguiste con lo del gym?"], cycle: 2)
        let probe = await w.engine.probeRequest(after: 60, title: "Lumen")
        #expect(probe.id == ReengagementIDs.probeId && probe.body == "¿Seguiste con lo del gym?")
        #expect(probe.trigger == .at(N.at(5, 15, 11)))
        #expect(!ReengagementIDs.isChain(probe.id))
    }

    @Test func contadorDePulsosDeHoy() async throws {
        let queue = try AnimaDatabase.temporary()
        let now = N.at(5, 15)
        try await queue.write { db in
            for ts in [N.at(5, 9), N.at(5, 14), N.at(4, 23)] {
                try db.execute(sql: "INSERT INTO desire_pulse (ts, day) VALUES (?, 'x')",
                               arguments: [ts.timeIntervalSince1970])
            }
        }
        let counter = ReengagementEngine.pulseCounter(queue: queue, calendar: N.cal, now: { now })
        #expect(await counter() == 2)
    }
}

// MARK: - Integración con la capa proactiva

@Suite struct ReengagementSchedulingTests {
    typealias N = NudgeFixtures

    @Test func syncProgramaLaCadenaJuntoAlResto() async throws {
        let w = try N.world()
        let reminder = try await w.reminders.create(text: "llamar", fireAt: N.at(8, 15, 30))
        let ids = await w.scheduler.sync()
        #expect(ids.contains("anima-reminder-\(reminder.id)"))
        #expect(w.fires().count == 4)
        // El del día 8 esquiva el recordatorio de las 15:30.
        #expect(w.fires().first == N.at(8, 12, 30))
    }

    @Test func sinPermisoNoSeProgramaNiSePidePorLosAvisos() async throws {
        let w = try N.world(status: .notDetermined)
        await w.scheduler.sync()
        #expect(w.fake.requestCount == 0)
        #expect(w.fires().isEmpty)
        // Control: un recordatorio (lo pidió el dueño) sí pide el permiso, y con él entra la cadena.
        _ = try await w.reminders.create(text: "llamar", fireAt: N.at(6, 9))
        await w.scheduler.sync()
        #expect(w.fake.requestCount == 1)
        #expect(w.fires().count == 4)
        let denied = try N.world(status: .denied)
        await denied.scheduler.sync()
        await denied.scheduler.ownerUsedAnima()
        #expect(denied.fires().isEmpty)
    }

    @Test func unTurnoReprogramaSoloLaCadena() async throws {
        let w = try N.world()
        await w.scheduler.sync()
        #expect(w.fires().first == N.at(8, 15))
        w.set(N.at(6, 11, 5))
        await w.scheduler.ownerUsedAnima()
        #expect(w.fires().first == N.at(9, 11))
        #expect(w.fires().count == 4)
    }

    @Test func apagarCancelaLaCadenaYElGeneralTambien() async throws {
        let defaults = N.defaults()
        let queue = try AnimaDatabase.temporary()
        let fake = FakeNotificationScheduler(status: .granted)
        let pref = ReengagementPreference(defaults: defaults)
        let general = ProactivePreference(defaults: defaults)
        let engine = ReengagementEngine(preference: pref, questions: ReengagementQuestionStore(queue: queue),
                                        planner: N.planner)
        let scheduler = ProactiveScheduler(scheduler: fake, reminders: AnimaReminderStore(queue: queue),
                                           calendar: N.cal, preference: general, reengagement: engine)
        await scheduler.sync()
        _ = await scheduler.scheduleProbeNudge(after: 60)
        #expect(fake.scheduled.keys.filter { $0.hasPrefix(ReengagementIDs.prefix) }.count == 5)
        pref.isEnabled = false
        await scheduler.syncReengagement()
        // Apagado: la cadena se va, y el "Probar" pendiente también.
        #expect(fake.scheduled.isEmpty)
        pref.isEnabled = true
        await scheduler.sync()
        _ = await scheduler.scheduleProbeNudge(after: 60)
        #expect(fake.scheduled.count == 5)
        general.isEnabled = false
        await scheduler.sync()
        #expect(fake.scheduled.isEmpty)
        #expect(await scheduler.scheduleProbeNudge(after: 60) == nil)
        #expect(await scheduler.syncReengagement().isEmpty)
    }

    @Test func probarPidePermisoPorqueLoPidioElDueno() async throws {
        let w = try N.world(status: .notDetermined)
        let probe = try #require(await w.scheduler.scheduleProbeNudge(after: 30))
        #expect(w.fake.requestCount == 1 && probe.id == ReengagementIDs.probeId)
        await w.scheduler.sync()
        #expect(w.fake.scheduled[ReengagementIDs.probeId] != nil)
        let denied = try N.world(status: .denied)
        #expect(await denied.scheduler.scheduleProbeNudge(after: 30) == nil)
    }

    @Test func losRecordatoriosGananLosCuposDeIOS() async throws {
        let queue = try AnimaDatabase.temporary()
        let clock = Locked(N.at(5, 15, 10))
        let now: @Sendable () -> Date = { clock.value }
        let reminders = AnimaReminderStore(queue: queue, calendar: N.cal, now: now)
        let engine = ReengagementEngine(preference: ReengagementPreference(defaults: N.defaults()),
                                        questions: nil, planner: N.planner, now: now)
        let fake = FakeNotificationScheduler(status: .granted)
        let scheduler = ProactiveScheduler(scheduler: fake, reminders: reminders, calendar: N.cal, maxPending: 6,
                                           reengagement: engine)
        for i in 0..<4 { _ = try await reminders.create(text: "r\(i)", fireAt: N.at(6 + i, 9)) }
        await scheduler.sync()
        #expect(fake.scheduled.count == 6)
        #expect(fake.scheduled.keys.filter(ReengagementIDs.isChain).count == 2)
        for i in 4..<6 { _ = try await reminders.create(text: "r\(i)", fireAt: N.at(6 + i, 9)) }
        await scheduler.syncReengagement()
        await scheduler.sync()
        #expect(fake.scheduled.keys.filter(ReengagementIDs.isChain).isEmpty)
    }

    @Test func sinMotorNadaCambia() async throws {
        let queue = try AnimaDatabase.temporary()
        let fake = FakeNotificationScheduler(status: .granted)
        let scheduler = ProactiveScheduler(scheduler: fake, reminders: AnimaReminderStore(queue: queue))
        await scheduler.ownerUsedAnima()
        #expect(await scheduler.syncReengagement().isEmpty)
        #expect(await scheduler.scheduleProbeNudge(after: 60) == nil)
        #expect(await scheduler.sync().isEmpty)
    }

    @Test func elTapDejaLaPreguntaEnElChatUnaVez() async throws {
        let w = try N.world()
        let saved = try w.questions.replace(with: ["¿Cómo te fue en la reunión con Pedro?"], cycle: 3)
        await w.scheduler.sync()
        w.set(N.at(8, 15, 1))
        let sid = try w.symbolic.startSession()
        let message = try #require(await w.reconciler.nudgePrompt(ref: saved[0].id, sessionId: sid))
        #expect(message.kind == .nudge(id: saved[0].id))
        #expect(message.text == "¿Cómo te fue en la reunión con Pedro?")
        _ = await w.reconciler.nudgePrompt(ref: saved[0].id, sessionId: sid)
        let turns = try w.symbolic.historyPage().turns.filter { $0.proactive?.kind == "nudge" }
        #expect(turns.count == 1)
        #expect(turns.first?.role == .assistant && turns.first?.text == message.text)
        let tag = try #require(turns.first?.proactive)
        let restored = try #require(ProactiveMessage(tag: tag, text: message.text))
        #expect(restored.kind == .nudge(id: saved[0].id))
        // El tap cuenta como uso: la cadena arranca desde el tap.
        await w.scheduler.syncReengagement()
        #expect(w.fires().first == N.at(11, 15))
        #expect(await w.reconciler.nudgePrompt(ref: "nope", sessionId: sid) == nil)
    }

    @Test func alAbrirSinTocarElAvisoTambienQuedaEnElChat() async throws {
        let w = try N.world()
        await w.scheduler.sync()
        w.set(N.at(8, 19))
        let sid = try w.symbolic.startSession()
        let messages = await w.reconciler.reconcileNudges(sessionId: sid)
        #expect(messages.map(\.text) == [ReengagementFallback.questions[0]])
        #expect(await w.reconciler.reconcileNudges(sessionId: sid).isEmpty)
        let bare = ProactiveReconciler(reminders: w.reminders)
        #expect(await bare.reconcileNudges(sessionId: sid).isEmpty)
        #expect(await bare.nudgePrompt(ref: "fallback-1", sessionId: sid) == nil)
    }

    @Test func tarjetaYDeepLink() {
        let kind = ProactiveMessage.Kind.nudge(id: "q1")
        #expect(kind.slug == "nudge" && kind.ref == "q1")
        #expect(ProactiveMessage.Kind(slug: "nudge", ref: "q1") == kind)
        #expect(ProactiveCard.symbol(kind) == "bubble.left.and.text.bubble.right")
        let dates = AnimaDateText(calendar: N.cal)
        #expect(ProactiveCard.label(kind, at: nil, goalStatement: nil, now: N.at(5, 9), dates: dates,
                                    selfName: "Lumen") == "Pregunta de Lumen")
        #expect(ProactiveCard.label(kind, at: nil, goalStatement: nil, now: N.at(5, 9), dates: dates) == "Pregunta")
        #expect(ProactiveCard.followUp(kind, at: N.at(1, 9), now: N.at(5, 9)) == nil)
        let url = AnimaDeepLink.nudge(id: "q1").url
        #expect(url.absoluteString == "anima://nudge?id=q1")
        #expect(AnimaDeepLink.parse(url) == .nudge(id: "q1"))
        #expect(AnimaDeepLink.parse(URL(string: "anima://nudge")!) == nil)
        let tap = "com.apple.UNNotificationDefaultActionIdentifier"
        #expect(ProactiveNotificationAction.from(actionIdentifier: tap, link: url) == .open(.nudge(id: "q1")))
    }

    @MainActor
    @Test func elChatPintaLaPreguntaComoCardSinDuplicar() async throws {
        let message = ProactiveMessage(kind: .nudge(id: "q1"), text: "¿Seguiste con lo del gym?", at: N.at(8, 15))
        let display = ChatViewModel.DisplayMessage.proactive(message)
        #expect(display.nudgeId == "q1" && display.proactiveKind == .nudge(id: "q1"))
    }
}

// MARK: - Lo que puede ir en el push

@Suite struct ReengagementTextGuardTests {
    @Test func aceptaPreguntasCalidasYCortas() {
        for ok in ["¿Cómo te fue en la reunión con Pedro?", "¿Seguiste con lo del gym?",
                   "¿Cómo has estado de ánimo esta semana?", "Hace rato no hablamos, ¿cómo estás?"] {
            #expect(ReengagementTextGuard.isAllowed(ok), "\(ok)")
        }
    }

    @Test func rechazaLoSensibleLoLargoYLoQueNoEsPregunta() {
        let rejected = [
            "¿Ya ahorraste los 10 millones?",                  // cifras
            "¿Cómo vas con la deuda de la tarjeta?",           // dinero
            "¿Te tomaste las pastillas para la ansiedad?",     // salud
            "¿Cómo te fue en la cita con el médico?",          // salud
            "¿Qué tal \"la reunión\"?",                        // citas
            "Cuéntame cómo vas.",                              // no es pregunta
            "¿Y?",                                             // muy corta
            String(repeating: "¿Cómo vas con todo lo que tenías pendiente ", count: 3) + "?",  // larga
        ]
        for text in rejected { #expect(!ReengagementTextGuard.isAllowed(text), "\(text)") }
        // Las de respaldo pasan su propio filtro.
        #expect(ReengagementFallback.questions.allSatisfy(ReengagementTextGuard.isAllowed))
        #expect(Set(ReengagementFallback.questions.map(ReengagementTextGuard.key)).count
                == ReengagementFallback.questions.count)
    }

    @Test func claveIgnoraTildesYSignos() {
        #expect(ReengagementTextGuard.key("¿Cómo VAS hoy?") == ReengagementTextGuard.key("como vas hoy"))
    }

    @Test func refsDeRespaldo() {
        #expect(ReengagementFallback.text(for: "fallback-0") == ReengagementFallback.questions[0])
        #expect(ReengagementFallback.text(for: "fallback-99") == nil)
        #expect(ReengagementFallback.text(for: "x-1") == nil)
    }
}

// MARK: - La etapa del sueño

@Suite struct ReengagementDraftTests {
    static let material = ReengagementDraft.Material(
        selfName: "Lumen", style: "Tono: cercano. Idioma por defecto: español (es-CO).", language: "español (es-CO)",
        memories: ["El dueño tiene una reunión con Pedro el jueves"], goals: ["Ir al gym 3 veces por semana (sin avances anotados)"],
        messages: ["mañana me reúno con Pedro por lo del proyecto"])

    @Test func promptConPersonaIdiomaYReglas() {
        let system = ReengagementDraft.system(Self.material)
        #expect(system.contains("Eres Lumen"))
        #expect(system.contains("Escribe en español (es-CO)"))
        #expect(system.contains("Tono: cercano"))
        #expect(system.contains("NADA de salud"))
        #expect(system.contains("Entre 3 y 5 preguntas"))
        let user = ReengagementDraft.user(Self.material)
        #expect(user.contains("reunión con Pedro el jueves"))
        #expect(user.contains("Ir al gym 3 veces"))
        #expect(user.contains("mañana me reúno con Pedro"))
        #expect(!Self.material.isEmpty)
        #expect(ReengagementDraft.Material(selfName: "A", style: "", language: "es", memories: [], goals: [],
                                           messages: []).isEmpty)
        #expect(!ReengagementDraft.system(.init(selfName: "A", style: "", language: "inglés (English)", memories: [],
                                                goals: [], messages: [])).contains("Tu estilo"))
    }

    @Test func parseoRobusto() {
        #expect(ReengagementDraft.parse(#"["¿Cómo te fue con Pedro?", "¿Seguiste con lo del gym?"]"#)
                == ["¿Cómo te fue con Pedro?", "¿Seguiste con lo del gym?"])
        #expect(ReengagementDraft.parse("Aquí van:\n```json\n[\"¿Cómo vas hoy?\"]\n```")  == ["¿Cómo vas hoy?"])
        #expect(ReengagementDraft.parse(#"[{"text":"¿Cómo vas hoy?"},{"question":"¿Qué planes tienes?"}]"#)
                == ["¿Cómo vas hoy?", "¿Qué planes tienes?"])
        #expect(ReengagementDraft.parse(#"{"questions":["¿Cómo vas hoy?"]}"#) == ["¿Cómo vas hoy?"])
        #expect(ReengagementDraft.parse("1. ¿Cómo vas hoy?\n- \"¿Qué planes tienes?\"\nGracias.")
                == ["¿Cómo vas hoy?", "¿Qué planes tienes?"])
        #expect(ReengagementDraft.parse("no entendí").isEmpty)
    }

    @Test func limiteDeCantidadLargoYFiltro() {
        let many = (1...8).map { "\"¿Pregunta distinta \(String(repeating: "a", count: $0))?\"" }.joined(separator: ",")
        #expect(ReengagementDraft.parse("[\(many)]").count == ReengagementDraft.maxQuestions)
        let mixed = #"["¿Cómo vas hoy?", "¿como vas hoy?", "¿Ya pagaste los 2 millones?", "¿Cómo va la terapia?", "Hola"]"#
        #expect(ReengagementDraft.parse(mixed) == ["¿Cómo vas hoy?"])
        #expect(ReengagementDraft.clean("  * «¿Cómo vas   hoy?»,") == "¿Cómo vas hoy?")
    }

    @Test func idiomaDelDueno() {
        let es = ["mañana tengo la reunión con Pedro y estoy un poco nervioso por el proyecto"]
        #expect(ReengagementDraft.language(of: es, fallback: "español (es-CO)") == "español (es-CO)")
        let en = ["tomorrow I have the meeting with Peter and I am a bit nervous about the project"]
        #expect(ReengagementDraft.language(of: en, fallback: "español (es-CO)") == "inglés (English)")
        #expect(ReengagementDraft.language(of: ["ok"], fallback: "español (es-CO)") == "español (es-CO)")
        #expect(ReengagementDraft.defaultLanguage(fromStyle: "Tono: x. Idioma por defecto: español (es-CO).")
                == "español (es-CO)")
        #expect(ReengagementDraft.defaultLanguage(fromStyle: "sin idioma") == "español")
        #expect(ReengagementDraft.shorten(String(repeating: "a", count: 200)).count == 161)
        #expect(ReengagementDraft.shorten("a\nb") == "a b")
    }
}

/// Captura el system y el user de cada llamada del ciclo.
final class PromptCapturingProvider: Provider, @unchecked Sendable {
    private let scripts: [[ProviderEvent]]
    private let index = Locked(0)
    let systems = Locked<[String]>([])
    let users = Locked<[String]>([])
    init(_ scripts: [[ProviderEvent]]) { self.scripts = scripts }

    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let i = index.mutate { current -> Int in let c = current; current += 1; return c }
        systems.mutate { $0.append(opts.systemPromptBase) }
        users.mutate { $0.append(ctx.messages.map { m in m.content.compactMap { b -> String? in
            if case .text(let t) = b { return t } else { return nil } }.joined() }.joined()) }
        let events = i < scripts.count ? scripts[i] : []
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

@Suite struct ConsolidatorReengagementTests {
    private struct Rig {
        let queue: DatabaseQueue
        let brain: Brain
        let inbox: ConsolidationInbox
        let other: OtherModel
        let questions: ReengagementQuestionStore
        let selfModel: SelfModel
        func consolidator(_ provider: Provider, nudges: Bool = true) throws -> Consolidator {
            Consolidator(brain: brain, queue: queue, provider: provider, router: try .haikuAll(), authMode: .apiKey,
                         token: "sk-ant-api03-x", selfModel: selfModel, otherModel: other,
                         nudgeQuestions: nudges ? questions : nil)
        }
    }

    private func rig() throws -> Rig {
        let queue = try AnimaDatabase.temporary()
        let selfModel = SelfModel(queue: queue, birth: Birth(name: "Lumen", tone: "cálido", language: "español (es-CO)"))
        return Rig(queue: queue, brain: Brain(queue: queue, embedder: Embedder(forceFallback: true)),
                   inbox: ConsolidationInbox(queue: queue), other: OtherModel(queue: queue),
                   questions: ReengagementQuestionStore(queue: queue), selfModel: selfModel)
    }

    static let noFacts = [ProviderEvent].text("[]")
    static let noGoals = [ProviderEvent].text("[]")
    static let questions = [ProviderEvent].text("""
        Claro:
        ["¿Cómo te fue en la reunión con Pedro?", "¿Seguiste con lo del gym?",
         "¿Ya pagaste los 3 millones?", "¿Cómo has estado de ánimo esta semana?"]
        """)

    @Test func elSuenoDejaLasPreguntasListas() async throws {
        let rig = try rig()
        try rig.inbox.enqueue(sessionId: "s1", text: "Mañana me reúno con Pedro por lo del proyecto, ando nervioso.")
        let provider = PromptCapturingProvider([Self.noFacts, Self.noGoals, Self.questions])
        let report = try await rig.consolidator(provider).cycle()
        #expect(report.completed)
        #expect(rig.questions.upcoming(limit: 10).map(\.text)
                == ["¿Cómo te fue en la reunión con Pedro?", "¿Seguiste con lo del gym?",
                    "¿Cómo has estado de ánimo esta semana?"])
        let system = try #require(provider.systems.value.last)
        #expect(system.contains("Eres Lumen") && system.contains("Escribe en español (es-CO)"))
        #expect(provider.users.value.last?.contains("me reúno con Pedro") == true)
        #expect(provider.systems.value.count == 3)
    }

    @Test func sinAlmacenLaEtapaNoGastaLlamada() async throws {
        let rig = try rig()
        try rig.inbox.enqueue(sessionId: "s1", text: "Mañana me reúno con Pedro.")
        let provider = PromptCapturingProvider([Self.noFacts, Self.noGoals, Self.questions])
        #expect(try await rig.consolidator(provider, nudges: false).cycle().completed)
        #expect(provider.systems.value.count == 2)
        #expect(rig.questions.upcoming(limit: 10).isEmpty)
    }

    @Test func sinMaterialNoLlamaYUnaRespuestaInservibleNoTumbaElCiclo() async throws {
        let empty = try rig()
        let quiet = PromptCapturingProvider([])
        #expect(try await empty.consolidator(quiet).cycle().completed)
        #expect(quiet.systems.value.isEmpty)

        let rig = try rig()
        try rig.questions.replace(with: ["¿Seguiste con lo del gym?"], cycle: 1)
        try rig.inbox.enqueue(sessionId: "s1", text: "Hoy fue un día largo en la oficina.")
        let garbage = PromptCapturingProvider([Self.noFacts, Self.noGoals, [ProviderEvent].text("lo siento")])
        #expect(try await rig.consolidator(garbage).cycle().completed)
        #expect(rig.questions.upcoming(limit: 10).map(\.text) == ["¿Seguiste con lo del gym?"])
        // Un fallo del córtex (stream vacío) tampoco.
        try rig.inbox.enqueue(sessionId: "s1", text: "Otro día largo.")
        let failing = PromptCapturingProvider([Self.noFacts, Self.noGoals])
        #expect(try await rig.consolidator(failing).cycle().completed)
        #expect(rig.questions.upcoming(limit: 10).count == 1)
    }

    @Test func materialConMetasYMemoriasRecientes() async throws {
        let rig = try rig()
        _ = try await rig.brain.add(MemoryCandidate(content: "El dueño tiene una reunión con Pedro", kind: .episodic,
                                                    importance: 8), cycle: 1)
        _ = try await rig.brain.add(MemoryCandidate(content: "Lección vieja", kind: .lesson), cycle: 1)
        _ = await rig.other.ingestStated(statement: "Ir al gym", desiredState: .progressCheckIn(everyDays: 3),
                                         evidence: "")
        let consolidator = try rig.consolidator(PromptCapturingProvider([]))
        let material = try #require(await consolidator.nudgeMaterial(cycle: 1))
        #expect(material.memories == ["El dueño tiene una reunión con Pedro"])
        #expect(material.goals == ["Ir al gym (sin avances anotados)"])
        #expect(material.selfName == "Lumen" && material.language == "español (es-CO)")
    }

    @Test func reanudaAntesDeLasPreguntas() async throws {
        let rig = try rig()
        try rig.inbox.enqueue(sessionId: "s1", text: "Mañana me reúno con Pedro.")
        let provider = PromptCapturingProvider([Self.noFacts, Self.noGoals, Self.questions])
        let consolidator = try rig.consolidator(provider)
        #expect(try await !consolidator.cycle(interrupting: { $0 == "goalsExtracted" }).completed)
        #expect(rig.questions.upcoming(limit: 10).isEmpty)
        #expect(try await consolidator.cycle().completed)
        #expect(rig.questions.upcoming(limit: 10).count == 3)
    }
}

// MARK: - Migración y almacén

@Suite struct ReengagementStoreTests {
    @Test func migracionAditivaConservaLoAnterior() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try AnimaDatabase.migrator().migrate(queue, upTo: "v18-intention-turn-tag")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO anima_reminder (id, text, fire_at, status, created_at) VALUES ('r1','x',1,'scheduled',1)
                """)
        }
        #expect(try queue.read { try $0.tableExists("reengagement_question") } == false)
        try AnimaDatabase.migrator().migrate(queue)
        #expect(try queue.read { try $0.tableExists("reengagement_question") })
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM anima_reminder") } == 1)
        let columns = try queue.read { try $0.columns(in: "reengagement_question").map(\.name) }
        #expect(columns == ["id", "text", "cycle", "rank", "created_at", "delivered_at", "retired_at"])
        #expect(try queue.read { try AnimaDatabase.migrator().hasCompletedMigrations($0) })
    }

    @Test func cadaNocheRetiraLasNoUsadasYNoRepiteLasEntregadas() throws {
        let queue = try AnimaDatabase.temporary()
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        let store = ReengagementQuestionStore(queue: queue, now: { clock.value })
        let first = try store.replace(with: ["¿Cómo vas hoy?", "¿Cómo vas hoy?", "¿Qué planes tienes?"], cycle: 1)
        #expect(first.map(\.text) == ["¿Cómo vas hoy?", "¿Qué planes tienes?"])
        store.markDelivered(id: first[0].id, at: clock.value)
        store.markDelivered(id: first[0].id, at: clock.value.addingTimeInterval(99))
        #expect(store.question(id: first[0].id)?.deliveredAt == clock.value)
        clock.mutate { $0 = $0.addingTimeInterval(86_400) }
        let second = try store.replace(with: ["¿Como vas hoy?", "¿Seguiste con lo del gym?"], cycle: 2)
        #expect(second.map(\.text) == ["¿Seguiste con lo del gym?"])
        #expect(store.upcoming(limit: 5).map(\.text) == ["¿Seguiste con lo del gym?"])
        #expect(store.question(id: first[1].id)?.retiredAt != nil)
        // Una tanda vacía no retira las vigentes.
        #expect(try store.replace(with: [], cycle: 3).isEmpty)
        #expect(store.upcoming(limit: 5).count == 1)
        #expect(store.question(id: "nope") == nil)
    }
}

// MARK: - Ajustes

@MainActor
@Suite struct ReengagementSettingsTests {
    @Test func toggleYDiasComoWakePreference() async throws {
        let defaults = NudgeFixtures.defaults()
        let fake = FakeNotificationScheduler(status: .granted)
        let pref = ReengagementPreference(defaults: defaults)
        let model = NotificationsSettingsModel(scheduler: fake, reminders: nil,
                                               preference: ProactivePreference(defaults: defaults), nudges: pref)
        let changes = Locked(0)
        model.onNudgeChanged = { changes.mutate { $0 += 1 } }
        model.onNudgeProbe = { true }
        await model.refresh()
        #expect(model.nudgeEnabled && model.nudgeDays == 3 && model.nudgeToggleIsOn && model.nudgeToggleIsEnabled)
        await model.setNudgeDays(5)
        #expect(pref.days == 5 && model.nudgeDays == 5)
        await model.setNudgeDays(4)
        #expect(pref.days == 5)
        await model.probeNudge()
        #expect(model.nudgeProbeScheduled)
        await model.setNudgeEnabled(false)
        #expect(!pref.isEnabled && !model.nudgeToggleIsOn && !model.nudgeProbeScheduled)
        #expect(changes.value == 2)
        #expect(NotificationsSettingsModel.nudgeDetail(days: 3) == "Si pasan 3 días sin que hablemos, te escribo una pregunta.")
        #expect(NotificationsSettingsModel.nudgeDaysLabel(2) == "2 días")
        // Sin permiso del iPhone el toggle se ve apagado y deshabilitado.
        let denied = NotificationsSettingsModel(scheduler: FakeNotificationScheduler(status: .denied), reminders: nil,
                                                nudges: ReengagementPreference(defaults: NudgeFixtures.defaults()))
        await denied.refresh()
        #expect(!denied.nudgeToggleIsOn && !denied.nudgeToggleIsEnabled)
        let bare = NotificationsSettingsModel(scheduler: fake, reminders: nil)
        await bare.probeNudge()
        #expect(!bare.nudgeProbeScheduled && bare.nudgeDays == 3)
    }
}

// MARK: - El turno del dueño reprograma (cualquier superficie)

@Suite struct OwnerTurnHookTests {
    @Test func cadaTurnoAvisaConSuSuperficie() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let provider = ScriptedProvider([[ProviderEvent].text("hola"), [ProviderEvent].text("listo")])
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x",
                             clientTools: [], serverTools: [], sleep: { _ in })
        let surfaces = Locked<[SurfaceID]>([])
        await loop.setOnOwnerTurn { surface in surfaces.mutate { $0.append(surface) } }
        let sid = try store.startSession()
        for await _ in await loop.run(sessionId: sid, userText: "hola") {}
        for await _ in await loop.run(sessionId: sid, content: [.text("¿qué tal?")], surface: .siri) {}
        await loop.waitUntilIdle()
        await eventually { surfaces.value.count == 2 }
        #expect(Set(surfaces.value) == [.phoneChat, .siri])
        // Sin hook el turno corre igual.
        await loop.setOnOwnerTurn(nil)
        for await _ in await loop.run(sessionId: sid, userText: "otra") {}
        await loop.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(50))
        #expect(surfaces.value.count == 2)
    }
}

/// Espera (con tope) a que algo que corre suelto termine.
func eventually(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
