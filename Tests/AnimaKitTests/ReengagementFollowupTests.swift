import Foundation
import GRDB
import Testing
@testable import AnimaKit

// Review del PR #42: zona horaria viva, plan = lo programado, filtro bilingüe,
// hook sin bloquear el loop, probe, aviso de despertar y transcript en cola.

private enum TZ {
    static let bogota = TimeZone(identifier: "America/Bogota")!
    static let madrid = TimeZone(identifier: "Europe/Madrid")!

    static func calendar(_ zone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    static func date(_ zone: TimeZone, _ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        calendar(zone).date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))!
    }

    static func hours(_ dates: [Date], in zone: TimeZone) -> [Int] {
        dates.map { calendar(zone).component(.hour, from: $0) }
    }
}

// MARK: - MEDIO 1: la ventana diurna sigue al dueño cuando viaja

@Suite struct ReengagementTimeZoneTests {
    typealias N = NudgeFixtures

    @Test func trasUnViajeSinRelanzarLosAvisosSiguenSiendoDeDia() async throws {
        let zone = Locked(TZ.bogota)
        let planner = ReengagementPlanner(calendarProvider: { TZ.calendar(zone.value) })
        let clock = Locked(TZ.date(TZ.bogota, 5, 9))
        let pref = ReengagementPreference(defaults: N.defaults())
        let engine = ReengagementEngine(preference: pref, questions: nil, planner: planner, now: { clock.value })
        _ = await engine.requests(others: [], title: "L")    // cableado en Bogotá
        // Vuela a Madrid (mismo proceso) y habla a las 22:00 de allá.
        zone.mutate { $0 = TZ.madrid }
        clock.mutate { $0 = TZ.date(TZ.madrid, 6, 22) }
        await engine.recordUse()
        let fires = await engine.requests(others: [], title: "L").compactMap { r -> Date? in
            if case .at(let d) = r.trigger { return d } else { return nil }
        }
        #expect(fires.count == 4)
        #expect(TZ.hours(fires, in: TZ.madrid).allSatisfy { (10...20).contains($0) })
        #expect(TZ.hours(fires, in: TZ.madrid).first == 20)
        // Control negativo: con el calendario congelado en Bogotá caen de noche en Madrid.
        let frozen = ReengagementPlanner(calendar: TZ.calendar(TZ.bogota))
            .chain(lastUse: TZ.date(TZ.madrid, 6, 22), days: 3, others: [], now: TZ.date(TZ.madrid, 6, 22))
        #expect(TZ.hours(frozen, in: TZ.madrid).allSatisfy { $0 >= 21 })
    }

    @Test func enLaAppElCalendarioEsElVivo() {
        let planner = ReengagementPlanner()
        #expect(planner.calendar.timeZone.identifier == TimeZone.autoupdatingCurrent.identifier)
    }
}

// MARK: - MEDIO 2: el plan guarda solo lo que de verdad se programó

@Suite struct ReengagementPlanIsWhatWasScheduledTests {
    typealias N = NudgeFixtures

    struct Rig {
        let clock: Locked<Date>
        let reminders: AnimaReminderStore
        let questions: ReengagementQuestionStore
        let engine: ReengagementEngine
        let saved: [ReengagementQuestion]
    }

    static func rig() throws -> Rig {
        let queue = try AnimaDatabase.temporary()
        let clock = Locked(N.at(5, 15, 10))
        let now: @Sendable () -> Date = { clock.value }
        let questions = ReengagementQuestionStore(queue: queue, now: now)
        let saved = try questions.replace(with: ["¿Cómo te fue en la reunión con Pedro?", "¿Seguiste con lo del gym?",
                                                 "¿Qué tal la visita de Ana?", "¿Qué planes tienes?"], cycle: 1)
        let engine = ReengagementEngine(preference: ReengagementPreference(defaults: N.defaults()),
                                        questions: questions, planner: N.planner, now: now)
        return Rig(clock: clock, reminders: AnimaReminderStore(queue: queue, calendar: N.cal, now: now),
                   questions: questions, engine: engine, saved: saved)
    }

    @Test func sinCupoNoHayCardsFantasmaNiPreguntasQuemadas() async throws {
        let r = try Self.rig()
        let fake = FakeNotificationScheduler(status: .granted)
        let scheduler = ProactiveScheduler(scheduler: fake, reminders: r.reminders, calendar: N.cal, maxPending: 6,
                                           reengagement: r.engine)
        for i in 0..<5 { _ = try await r.reminders.create(text: "r\(i)", fireAt: N.at(6 + i, 9)) }
        await scheduler.sync()
        #expect(fake.scheduled.keys.filter(ReengagementIDs.isChain).count == 1)   // cupo para 1
        // Pasa la hora del 2.º aviso (que nunca se programó).
        r.clock.mutate { $0 = N.at(11, 16) }
        let unseen = await r.engine.unseenRecent()
        #expect(unseen.isEmpty, "el 2.º aviso no sonó: no hay card")
        #expect(r.questions.question(id: r.saved[0].id)?.deliveredAt != nil)
        #expect(r.questions.question(id: r.saved[1].id)?.deliveredAt == nil, "la 2.ª pregunta sigue libre")
    }

    @Test func controlConCupoElSegundoSiCuenta() async throws {
        let r = try Self.rig()
        let scheduler = ProactiveScheduler(scheduler: FakeNotificationScheduler(status: .granted),
                                           reminders: r.reminders, calendar: N.cal, reengagement: r.engine)
        await scheduler.sync()
        r.clock.mutate { $0 = N.at(11, 16) }
        // El del 8 ya quedó atrás (>12 h); el del 11 sí sonó y se pinta.
        #expect(await r.engine.unseenRecent().map(\.text) == ["¿Seguiste con lo del gym?"])
        #expect(r.questions.question(id: r.saved[1].id)?.deliveredAt != nil)
    }

    @Test func sinPermisoElPlanSeVacia() async throws {
        let r = try Self.rig()
        let granted = ProactiveScheduler(scheduler: FakeNotificationScheduler(status: .granted),
                                         reminders: r.reminders, calendar: N.cal, reengagement: r.engine)
        await granted.sync()
        // El dueño revoca el permiso en Ajustes de iOS: la próxima sincronización lo ve.
        let revoked = ProactiveScheduler(scheduler: FakeNotificationScheduler(status: .denied),
                                         reminders: r.reminders, calendar: N.cal, reengagement: r.engine)
        await revoked.sync()
        r.clock.mutate { $0 = N.at(8, 16) }
        #expect(await r.engine.unseenRecent().isEmpty)
        #expect(r.questions.question(id: r.saved[0].id)?.deliveredAt == nil)
        // Con el ownerUsedAnima (turno) sin permiso, igual.
        await revoked.ownerUsedAnima()
        #expect(await r.engine.unseenRecent().isEmpty)
    }

    @Test func apagarLosAvisosGeneralesVaciaElPlan() async throws {
        let r = try Self.rig()
        let defaults = N.defaults()
        let general = ProactivePreference(defaults: defaults)
        let scheduler = ProactiveScheduler(scheduler: FakeNotificationScheduler(status: .granted),
                                           reminders: r.reminders, calendar: N.cal, preference: general,
                                           reengagement: r.engine)
        await scheduler.sync()
        general.isEnabled = false
        await scheduler.sync()
        r.clock.mutate { $0 = N.at(8, 16) }
        #expect(await r.engine.unseenRecent().isEmpty)
    }
}

// MARK: - MEDIO 3: filtro bilingüe por palabra

@Suite struct ReengagementBilingualGuardTests {
    @Test func rechazaSaludDineroLegalAdiccionesYPareja() {
        let rejected = [
            "¿Cómo te fue con el doctor?", "¿Qué tal tu terapeuta?", "¿Cómo vas con el tratamiento?",
            "¿Cómo salió la operación?", "¿Pudiste pagar el arriendo?", "¿Cómo va la inversión en cripto?",
            "¿Pudiste ahorrar algo?", "¿Cómo vas con el divorcio?", "¿Hablaste con el abogado?",
            "¿Hubo novedades con la demanda?", "¿Cómo vas con el alcohol?", "¿Qué tal tu novia?",
            "¿Ya sacaste la tarjeta de crédito?", "¿Cómo va la plata del mes?",
            "How was the doctor appointment?", "Did you pay off the loan?", "How is therapy going?",
            "Did you take your meds?", "How are things with your girlfriend?", "Any news from the lawyer?",
        ]
        for text in rejected {
            #expect(!ReengagementTextGuard.isAllowed(text), "\(text)")
        }
    }

    @Test func sinFalsosPositivosPorPalabraOFrase() {
        let allowed = [
            "¿Qué tal la plataforma nueva?", "¿Le compraste la tarjeta de cumpleaños?", "¿Cómo se siente?",
            "¿Cómo va el proyecto de noviembre?", "¿Cómo te fue en la reunión con Pedro?",
            "¿Seguiste con lo del gym?", "How was the trip with your friends?",
            "¿Qué tal la cooperación con el equipo?",
        ]
        for text in allowed {
            #expect(ReengagementTextGuard.isAllowed(text), "\(text) → \(ReengagementTextGuard.sensitiveHit(text) ?? "")")
        }
        #expect(ReengagementFallback.questions.allSatisfy(ReengagementTextGuard.isAllowed))
    }

    @Test func elPromptPideNoPreguntarPorOtros() {
        let system = ReengagementDraft.system(.init(selfName: "Lumen", style: "", language: "español",
                                                    memories: [], goals: [], messages: []))
        #expect(system.contains("No preguntes por la salud, el dinero ni la vida privada de otras personas."))
    }
}

// MARK: - Menores

private struct BlockingTool: SensorimotorTool {
    let started: Locked<Bool>
    let release: Locked<Bool>
    var spec: ToolSpec { .client(name: "blocker", description: "x", inputSchema: .object(["type": .string("object")])) }
    func execute(_ input: JSONValue) async -> ToolResult {
        started.mutate { $0 = true }
        while !release.value { try? await Task.sleep(for: .milliseconds(5)) }
        return ToolResult(content: "ok")
    }
}

/// tool_use de `blocker`; tras su resultado, texto.
private final class BlockerProvider: Provider, @unchecked Sendable {
    func complete(_ ctx: AssembledContext, tools: [ToolSpec], opts: CallOpts)
        -> AsyncThrowingStream<ProviderEvent, Error> {
        let last = ctx.messages.last(where: { $0.role == .user })?.content ?? []
        let afterTool = last.contains { if case .toolResult = $0 { return true }; return false }
        let events: [ProviderEvent] = afterTool
            ? [.messageStart(id: "t", model: "x"), .textDelta("Listo."), .blockStop(index: 0),
               .messageDelta(stopReason: .endTurn, usage: Usage()), .messageStop]
            : [.messageStart(id: "u", model: "x"), .toolUseStart(id: "toolu_\(UUID().uuidString.prefix(6))", name: "blocker"),
               .toolUseInputDelta("{}"), .blockStop(index: 0), .messageDelta(stopReason: .toolUse, usage: Usage()),
               .messageStop]
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }
}

@Suite struct ReengagementMinorFollowupTests {
    typealias N = NudgeFixtures

    // El hook corre suelto: un hook lento no frena el siguiente turno ni waitUntilIdle.
    @Test func elHookNoBloqueaElLoop() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let provider = ScriptedProvider([[ProviderEvent].text("hola"), [ProviderEvent].text("otra vez")])
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x",
                             clientTools: [], serverTools: [], sleep: { _ in })
        let gate = Locked(false)
        let calls = Locked(0)
        await loop.setOnOwnerTurn { _ in
            calls.mutate { $0 += 1 }
            while !gate.value { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let sid = try store.startSession()
        for await _ in await loop.run(sessionId: sid, userText: "uno") {}
        for await _ in await loop.run(sessionId: sid, userText: "dos") {}
        await loop.waitUntilIdle()
        #expect(await loop.turnsInFlight == 0)
        await eventually { calls.value == 2 }
        #expect(calls.value == 2)
        gate.mutate { $0 = true }
    }

    @Test func unTurnoCanceladoEnColaNoDisparaElHook() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let started = Locked(false)
        let release = Locked(false)
        let loop = AgentLoop(provider: BlockerProvider(), store: store, telemetry: Telemetry(queue: queue),
                             router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x",
                             clientTools: [BlockingTool(started: started, release: release)], serverTools: [],
                             sleep: { _ in })
        let surfaces = Locked<[SurfaceID]>([])
        await loop.setOnOwnerTurn { surface in surfaces.mutate { $0.append(surface) } }
        let sid = try store.startSession()
        let first = await loop.run(sessionId: sid, userText: "uno")
        let consumeFirst = Task { for await _ in first {} }
        await eventually { started.value }
        // El segundo queda en cola detrás del primero y su consumidor corta antes de que arranque.
        let queued = await loop.run(sessionId: sid, content: [.text("dos")], surface: .siri)
        let consumeQueued = Task { for await _ in queued {} }
        consumeQueued.cancel()
        _ = await consumeQueued.value
        release.mutate { $0 = true }
        _ = await consumeFirst.value
        await loop.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(surfaces.value == [.phoneChat])
    }

    // La card en cola con los turnos: jamás entre el tool_use y su tool_result.
    @Test func lasCardsEsperanAlTurnoEnVuelo() async throws {
        let order = try await Self.transcriptOrder(gated: true)
        #expect(order == ["user", "assistant:tool_use", "user:tool_result", "assistant", "assistant:proactive"])
    }

    @Test func controlSinColaLaCardSeIntercala() async throws {
        let order = try await Self.transcriptOrder(gated: false)
        #expect(order == ["user", "assistant:tool_use", "assistant:proactive", "user:tool_result", "assistant"])
    }

    /// Un turno con tool en vuelo y, a mitad, un recordatorio vencido que se
    /// reconcilia (mismo camino que avisos, check-ins y propuestas).
    static func transcriptOrder(gated: Bool) async throws -> [String] {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let started = Locked(false)
        let release = Locked(false)
        let loop = AgentLoop(provider: BlockerProvider(), store: store, telemetry: Telemetry(queue: queue),
                             router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x",
                             clientTools: [BlockingTool(started: started, release: release)], serverTools: [],
                             sleep: { _ in })
        let clock = Locked(N.at(5, 9))
        let reminders = AnimaReminderStore(queue: queue, calendar: N.cal, now: { clock.value })
        _ = try await reminders.create(text: "llamar", fireAt: N.at(5, 10))
        let reconciler = ProactiveReconciler(reminders: reminders, store: store, calendar: N.cal, now: { clock.value })
        if gated {
            await reconciler.setTranscriptGate { sid, write in await loop.appendAfterTurns(sessionId: sid, write) }
        }
        let sid = try store.startSession()
        let turn = await loop.run(sessionId: sid, userText: "hazlo")
        let consume = Task { for await _ in turn {} }
        await eventually { started.value }
        clock.mutate { $0 = N.at(5, 11) }
        let reconcile = Task { await reconciler.reconcileDueReminders(sessionId: sid) }
        try await Task.sleep(for: .milliseconds(100))
        release.mutate { $0 = true }
        _ = await consume.value
        _ = await reconcile.value
        await loop.waitUntilIdle()
        return try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT role, content_json, proactive_json FROM turn_event ORDER BY id")
                .map { row -> String in
                    let role: String = row["role"]
                    let json: String = row["content_json"]
                    if (row["proactive_json"] as String?) != nil { return role + ":proactive" }
                    if json.contains("\"tool_use\"") || json.contains("toolUse") { return role + ":tool_use" }
                    if json.contains("\"tool_result\"") || json.contains("toolResult") { return role + ":tool_result" }
                    return role
                }
        }
    }

    @Test func elProbeNoDuplicaNiQuemaLaPreguntaDeLaCadena() async throws {
        let w = try N.world()
        let saved = try w.questions.replace(with: ["¿Cómo te fue en la reunión con Pedro?", "¿Seguiste con lo del gym?",
                                                   "¿Qué tal la visita de Ana?", "¿Qué planes tienes?",
                                                   "¿Cómo va el proyecto nuevo?"], cycle: 1)
        await w.scheduler.sync()
        #expect(w.chain().first?.body == saved[0].text)
        // El probe lleva la mejor (la real del sueño) y la cadena la suelta.
        let probe = try #require(await w.scheduler.scheduleProbeNudge(after: 60))
        #expect(probe.body == saved[0].text)
        #expect(!w.chain().map(\.body).contains(probe.body))
        #expect(w.chain().map(\.body) == Array(saved[1...4].map(\.text)))
        #expect(w.questions.question(id: saved[0].id)?.deliveredAt == nil)
        // Sin cadena (todo libre), el probe toma la primera y la cadena ya no la repite.
        let fresh = try N.world()
        let q = try fresh.questions.replace(with: ["¿Cómo te fue en la reunión con Pedro?",
                                                   "¿Seguiste con lo del gym?"], cycle: 1)
        let early = try #require(await fresh.scheduler.scheduleProbeNudge(after: 60))
        #expect(early.body == q[0].text)
        await fresh.scheduler.sync()
        #expect(!fresh.chain().map(\.body).contains(q[0].text))
        #expect(fresh.chain().first?.body == q[1].text)
        // Suena el probe: su pregunta queda entregada (y el tap la resuelve).
        fresh.set(N.at(5, 15, 12))
        _ = await fresh.engine.reconcileDelivered()
        #expect(fresh.questions.question(id: q[0].id)?.deliveredAt != nil)
        #expect(await fresh.engine.open(ref: q[0].id)?.delivery.text == q[0].text)
    }

    @Test func elDespertarCuentaParaLaDistanciaYElTope() async throws {
        let defaults = N.defaults()
        let wake = WakePreference(defaults: defaults)
        let clock = Locked(N.at(5, 9))
        let engine = ReengagementEngine(preference: ReengagementPreference(defaults: defaults), questions: nil,
                                        planner: N.planner, wake: wake, now: { clock.value })
        await engine.recordUse()
        // Uso a las 9 → preferida 10:00, a 2.5 h del despertar de las 7:30 → 10:30.
        #expect(await engine.requests(others: [], title: "L").first?.trigger == .at(N.at(8, 10, 30)))
        // Control: sin aviso de despertar va a las 10:00.
        wake.isEnabled = false
        #expect(await engine.requests(others: [], title: "L").first?.trigger == .at(N.at(8, 10)))
        // Tope: 3 recordatorios + el despertar = 4 ese día → pasa al siguiente.
        wake.isEnabled = true
        let busy = [N.at(8, 14), N.at(8, 17), N.at(8, 20)].enumerated().map { N.reminder("r\($0.offset)", at: $0.element) }
        let capped = await engine.requests(others: busy, title: "L").first?.trigger
        #expect(capped == .at(N.at(9, 10, 30)))
        wake.isEnabled = false
        #expect(await engine.requests(others: busy, title: "L").first?.trigger == .at(N.at(8, 10)))
    }
}
