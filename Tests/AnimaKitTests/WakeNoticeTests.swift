import Foundation
import Testing
@testable import AnimaKit

// Campo batch 8 #7: "cuando termine el sueño o en la mañana, un push indicando
// que se ejecutó correctamente, con mensaje bacano; que el usuario sepa que
// Anima se despertó y consolidó lo del día anterior".

@Suite("Batch 8 #7 — el aviso de despertar")
struct WakeNoticeTests {
    static let cal = ProactiveFixtures.calendar
    static func at(_ h: Int, _ m: Int = 0, day: Int = 7) -> Date { ProactiveFixtures.date(2026, 10, day, h, m) }

    static func report(added: Int = 0, updated: Int = 0, invalidated: Int = 0, reconsolidated: Int = 0,
                       goals: Int = 0, completed: Bool = true) -> Consolidator.CycleReport {
        Consolidator.CycleReport(cycle: 6, distilled: added, added: added, updated: updated, invalidated: invalidated,
                                 noop: 0, reconsolidated: reconsolidated, reflectionSummary: "", completed: completed,
                                 goalsUpdated: goals)
    }

    @Test func plantillasDeterministasEnSuVoz() {
        let morning = Self.at(7, 30)
        #expect(WakeNotice.body(Self.report(added: 4, goals: 1), night: 6, at: morning, calendar: Self.cal)
                == "Buenos días. Dormí y ordené lo de ayer: 4 recuerdos nuevos y 1 meta al día. Noche #6.")
        #expect(WakeNotice.body(Self.report(added: 1, updated: 1, reconsolidated: 1, goals: 2), night: 7, at: morning,
                                calendar: Self.cal)
                == "Buenos días. Ya desperté: consolidé lo de ayer — 1 recuerdo nuevo, 2 recuerdos afinados y 2 metas al día. Noche #7.")
        #expect(WakeNotice.body(Self.report(invalidated: 1), night: 8, at: morning, calendar: Self.cal)
                == "Buenos días. Mientras dormías ordené lo de ayer: 1 recuerdo corregido. Noche #8.")
        #expect(WakeNotice.body(Self.report(), night: 6, at: morning, calendar: Self.cal)
                == "Buenos días. Dormí bien; ayer no dejó nada nuevo que guardar.")
        // Misma entrada ⇒ mismo texto (sin LLM).
        #expect(WakeNotice.body(Self.report(added: 2), night: 9, at: morning, calendar: Self.cal)
                == WakeNotice.body(Self.report(added: 2), night: 9, at: morning, calendar: Self.cal))
        #expect(WakeNotice.greeting(at: Self.at(15), calendar: Self.cal) == "Buenas tardes")
        #expect(WakeNotice.greeting(at: Self.at(22), calendar: Self.cal) == "Buenas noches")
    }

    @Test func deNocheEsperaALas730DeDiaAvisaYa() {
        #expect(WakeNotice.fireDate(completedAt: Self.at(2, 10), calendar: Self.cal) == Self.at(7, 30))
        #expect(WakeNotice.fireDate(completedAt: Self.at(23, 40), calendar: Self.cal) == Self.at(7, 30, day: 8))
        #expect(WakeNotice.fireDate(completedAt: Self.at(7, 29), calendar: Self.cal) == Self.at(7, 30))
        #expect(WakeNotice.fireDate(completedAt: Self.at(7, 45), calendar: Self.cal) == Self.at(7, 45))
        #expect(WakeNotice.fireDate(completedAt: Self.at(15), calendar: Self.cal) == Self.at(15))
        #expect(WakeNotice.id(for: Self.at(7, 30), calendar: Self.cal) == "anima-wake-2026-10-07")
    }

    private func notifier(_ fake: FakeNotificationScheduler, clock: Locked<Date>,
                          general: ProactivePreference? = nil, wake: WakePreference) -> WakeNotifier {
        WakeNotifier(scheduler: fake, general: general, preference: wake, selfName: { "Budosky" },
                     calendar: Self.cal, now: { clock.value })
    }

    private func defaults() -> UserDefaults {
        let suite = "wake-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func programaUnoPorDiaConTituloYDeepLink() async throws {
        let fake = FakeNotificationScheduler(status: .granted)
        let clock = Locked(Self.at(2, 10))
        let wake = WakePreference(defaults: defaults())
        let n = notifier(fake, clock: clock, wake: wake)
        let request = try #require(await n.cycleCompleted(Self.report(added: 4, goals: 1), night: 6))
        #expect(request.title == "Budosky")
        #expect(request.trigger == .at(Self.at(7, 30)))
        #expect(request.categoryId == WakeNotice.category)
        #expect(request.deepLink == AnimaDeepLink.mind.url)
        #expect(AnimaDeepLink.parse(request.deepLink!) == .mind)
        // Otro ciclo la misma noche (reanudado / fallback): no hay segundo aviso.
        clock.mutate { $0 = Self.at(4) }
        #expect(await n.cycleCompleted(Self.report(added: 1), night: 7) == nil)
        #expect(fake.scheduled.count == 1)
        // La noche siguiente sí.
        clock.mutate { $0 = Self.at(1, day: 8) }
        #expect(await n.cycleCompleted(Self.report(), night: 7) != nil)
        #expect(fake.scheduled.count == 2)
    }

    @Test func deDiaVaInmediatoYUnCicloIncompletoNoAvisa() async throws {
        let fake = FakeNotificationScheduler(status: .granted)
        let n = notifier(fake, clock: Locked(Self.at(15)), wake: WakePreference(defaults: defaults()))
        #expect(await n.cycleCompleted(Self.report(added: 1, completed: false), night: 3) == nil)
        let request = try #require(await n.cycleCompleted(Self.report(added: 1), night: 3))
        #expect(request.trigger == .immediate)
        #expect(request.body.hasPrefix("Buenas tardes."))
    }

    @Test func respetaLosTogglesYElPermiso() async throws {
        let store = defaults()
        let general = ProactivePreference(defaults: store)
        let wake = WakePreference(defaults: store)
        #expect(wake.isEnabled)   // default ON
        let denied = FakeNotificationScheduler(status: .denied)
        #expect(await notifier(denied, clock: Locked(Self.at(2)), general: general, wake: wake)
            .cycleCompleted(Self.report(added: 1), night: 1) == nil)
        let fake = FakeNotificationScheduler(status: .granted)
        wake.isEnabled = false
        #expect(await notifier(fake, clock: Locked(Self.at(2)), general: general, wake: wake)
            .cycleCompleted(Self.report(added: 1), night: 1) == nil)
        wake.isEnabled = true
        general.isEnabled = false
        #expect(await notifier(fake, clock: Locked(Self.at(2)), general: general, wake: wake)
            .cycleCompleted(Self.report(added: 1), night: 1) == nil)
        general.isEnabled = true
        let n = notifier(fake, clock: Locked(Self.at(2)), general: general, wake: wake)
        #expect(await n.cycleCompleted(Self.report(added: 1), night: 1) != nil)
        await n.cancelPending()
        #expect(fake.scheduled.isEmpty)
    }

    @Test func apagarLosAvisosCancelaTambienElDeDespertar() async throws {
        let w = try ProactiveFixtures.world()
        await w.fake.schedule(LocalNotificationRequest(id: "anima-wake-2026-10-07", title: "t", body: "b",
                                                       trigger: .immediate, categoryId: WakeNotice.category,
                                                       deepLink: nil))
        let pref = ProactivePreference(defaults: defaults())
        pref.isEnabled = false
        let scheduler = ProactiveScheduler(scheduler: w.fake, reminders: w.reminders, preference: pref)
        await scheduler.sync()
        #expect(w.fake.scheduled.isEmpty)
    }

    @Test func elHolderAvisaSoloAlCompletarElCiclo() async throws {
        let queue = try AnimaDatabase.temporary()
        let consolidator = Consolidator(brain: Brain(queue: queue, embedder: Embedder(forceFallback: true)),
                                        queue: queue, provider: ScriptedProvider([]), router: try .haikuAll(),
                                        authMode: .apiKey, token: "sk-ant-api03-x")
        let holder = ConsolidatorHolder()
        let seen = Locked<[(Int, Bool)]>([])
        #expect(await holder.run(isExpired: { false }) == false)   // sin cablear
        holder.set(consolidator, scheduler: SleepScheduler(), onCompleted: { report, night in
            seen.mutate { $0.append((night, report.completed)) }
        })
        #expect(await holder.run(isExpired: { true }) == false)    // cortado: sin aviso
        #expect(seen.value.isEmpty)
        #expect(await holder.run(isExpired: { false }))
        #expect(seen.value.count == 1 && seen.value.first?.0 == 1 && seen.value.first?.1 == true)
    }

    @Test func elReporteCuentaLasMetasDelCiclo() async throws {
        let queue = try AnimaDatabase.temporary()
        let other = OtherModel(queue: queue)
        let inbox = ConsolidationInbox(queue: queue)
        try inbox.enqueue(sessionId: "s", text: "Quiero bajar 10 kg")
        let consolidator = Consolidator(brain: Brain(queue: queue, embedder: Embedder(forceFallback: true)),
                                        queue: queue, provider: ScriptedProvider([
                                            .text("[]"),
                                            .text(#"[{"statement":"Bajar 10 kg","evidence":"q","priority":5,"predicate":{"kind":"progress_check_in","every_days":7}}]"#),
                                        ]), router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x",
                                        otherModel: other)
        let report = try await consolidator.cycle()
        #expect(report.completed && report.goalsUpdated == 1)
    }
}

@MainActor
@Suite("Batch 8 #7 — Ajustes: Avisarme cuando despierte")
struct WakeSettingsTests {
    @Test func elToggleRespetaElGeneral() async throws {
        let store = UserDefaults(suiteName: "wake-settings-\(UUID().uuidString)")!
        let general = ProactivePreference(defaults: store)
        let wake = WakePreference(defaults: store)
        let fake = FakeNotificationScheduler(status: .granted)
        let model = NotificationsSettingsModel(scheduler: fake, reminders: nil, preference: general, wake: wake)
        await model.refresh()
        #expect(model.wakeToggleIsOn && model.wakeToggleIsEnabled)
        let changed = Locked<[Bool]>([])
        model.onWakeChanged = { on in changed.mutate { $0.append(on) } }
        await model.setWakeEnabled(false)
        #expect(!wake.isEnabled && !model.wakeToggleIsOn)
        #expect(changed.value == [false])
        await model.setWakeEnabled(true)
        await model.setEnabled(false)
        #expect(!model.wakeToggleIsOn && !model.wakeToggleIsEnabled)   // general apagado ⇒ también este
        #expect(wake.isEnabled)                                         // su preferencia se conserva
    }
}
