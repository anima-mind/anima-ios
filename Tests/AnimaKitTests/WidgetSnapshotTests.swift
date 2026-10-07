import Foundation
import Testing
import GRDB
@testable import AnimaKit

/// Snapshot de widgets: contenido, orden, proyección del día y vacío amable.
@Suite struct WidgetSnapshotTests {

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Bogota")!
        return c
    }()

    /// Miércoles 7 oct 2026, 8:00 a. m. (Bogotá).
    static let wednesday8am: Date = {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 8, minute: 0))!
    }()

    static func at(_ hour: Int, _ minute: Int = 0, day: Int = 7) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    struct World {
        let queue: DatabaseQueue
        let clock: Locked<Date>
        let reminders: AnimaReminderStore
        let other: OtherModel
        let selfModel: SelfModel

        init(now: Date = WidgetSnapshotTests.wednesday8am) throws {
            queue = try AnimaDatabase.temporary()
            let clock = Locked(now)
            self.clock = clock
            reminders = AnimaReminderStore(queue: queue, calendar: WidgetSnapshotTests.calendar,
                                           now: { clock.value })
            other = OtherModel(queue: queue, calendar: WidgetSnapshotTests.calendar, now: { clock.value })
            selfModel = SelfModel(queue: queue, now: { clock.value })
        }

        var builder: WidgetSnapshotBuilder {
            let clock = self.clock
            return WidgetSnapshotBuilder(reminders: reminders, otherModel: other, selfModel: selfModel,
                                         now: { clock.value })
        }
    }

    // MARK: - Builder

    @Test func builderCollectsRemindersGoalsAndSelf() async throws {
        let w = try World()
        let cal = Self.calendar
        // Ayer: un uno-a-uno entregado sin "Hecho" y un avance en la meta.
        w.clock.mutate { $0 = Self.at(7, day: 6) }
        let delivered = try await w.reminders.create(text: "Tomar la pastilla", fireAt: Self.at(7, 30, day: 6))
        let goalId = await w.other.ingestStated(statement: "Ahorrar 10M", desiredState: .progressCheckIn(everyDays: 1),
                                                evidence: "t")
        _ = await w.other.setCheckIn(id: goalId, CheckInCadence(cadence: .daily, hour: 20, minute: 0))
        w.clock.mutate { $0 = Self.at(20, 5, day: 6) }
        _ = await w.other.recordCheckIn(goalId: goalId, answer: .yes)
        w.clock.mutate { $0 = Self.at(7, 40, day: 6) }
        await w.reminders.markFired(id: delivered.id)
        // Hoy 8:00.
        w.clock.mutate { $0 = Self.wednesday8am }
        let late = try await w.reminders.create(text: "Pagar la tarjeta", fireAt: Self.at(18, 30))
        let soon = try await w.reminders.create(text: "Llamar al banco", fireAt: Self.at(9))
        let daily = try await w.reminders.create(text: "Agua", fireAt: Self.at(10), repeat: .daily)
        _ = await w.other.infer(statement: "Dormir más", desiredState: .progressCheckIn(everyDays: 1), evidence: "t")
        await w.selfModel.setCycles(12)

        let snapshot = await w.builder.build()

        #expect(snapshot.version == WidgetSnapshot.currentVersion)
        #expect(snapshot.generatedAt == Self.wednesday8am)
        #expect(snapshot.selfName == Birth.seed.name)
        #expect(snapshot.nights == 12)
        #expect(snapshot.plasticity == Plasticity.value(cycles: 12))
        // Programados por fecha y luego el entregado.
        #expect(snapshot.reminders.map(\.id) == [soon.id, daily.id, late.id, delivered.id])
        #expect(snapshot.reminders.last?.delivered == true)
        #expect(snapshot.reminders[1].cadence == .daily)
        // Solo metas que motivan (la inferida sin confirmar no).
        #expect(snapshot.goals.map(\.statement) == ["Ahorrar 10M"])
        #expect(snapshot.goals[0].streak == 1)
        #expect(snapshot.goals[0].checkIn.cadence == .daily)
        #expect(snapshot.goals[0].lastProgressAt.map { cal.isDate($0, inSameDayAs: Self.at(20, day: 6)) } == true)

        let day = snapshot.day(at: Self.wednesday8am, calendar: cal)
        #expect(day.next?.text == "Llamar al banco")
        #expect(day.reminders.map(\.text) == ["Llamar al banco", "Agua", "Pagar la tarjeta"])
        #expect(day.checkIns.map(\.statement) == ["Ahorrar 10M"])
        #expect(day.pendingCheckIn?.at == Self.at(20))
        #expect(day.goals.first?.streak == 1)
        #expect(!day.isEmpty)
    }

    @Test func builderWithoutStoresIsTheFriendlyEmpty() async {
        let snapshot = await WidgetSnapshotBuilder(reminders: nil, otherModel: nil, selfModel: nil,
                                                   now: { WidgetSnapshotTests.wednesday8am }).build()
        #expect(snapshot.reminders.isEmpty)
        #expect(snapshot.goals.isEmpty)
        #expect(snapshot.nights == 0)
        let day = snapshot.day(at: Self.wednesday8am, calendar: Self.calendar)
        #expect(day.isEmpty)
        #expect(day.next == nil)
        #expect(day.goal(id: nil) == nil)
        #expect(WidgetCopy(calendar: Self.calendar).lockLine(day) == "Nada pendiente hoy")
        #expect(WidgetCopy.emptyToday == "Nada pendiente hoy")
    }

    // MARK: - Proyección

    @Test func dayProjectionRollsAcrossMidnightWithoutTheApp() {
        let snapshot = WidgetSnapshot(
            generatedAt: Self.wednesday8am, selfName: "Budosky", plasticity: 0.5, nights: 3,
            reminders: [
                .init(id: "a", text: "Llamar al banco", fireAt: Self.at(9)),
                .init(id: "b", text: "Mañana temprano", fireAt: Self.at(7, day: 8)),
                .init(id: "d", text: "Agua", fireAt: Self.at(10, day: 5), cadence: .daily),
                .init(id: "e", text: "Entregado anteayer", fireAt: Self.at(7, day: 5), delivered: true),
            ],
            goals: [
                .init(id: "g", statement: "Leer", checkIn: CheckInCadence(cadence: .weekdays, hour: 21, minute: 0),
                      streak: 4, lastProgressAt: Self.at(21, day: 6), lastAnsweredAt: Self.at(21, day: 6)),
            ])
        let cal = Self.calendar
        // Hoy 9:30: el de las 9 quedó vencido, el próximo es el de Agua (rodado a hoy).
        let morning = snapshot.day(at: Self.at(9, 30), calendar: cal)
        #expect(morning.reminders.map(\.id) == ["a", "d"])
        #expect(morning.reminders.first?.overdue == true)
        #expect(morning.reminders.last?.at == Self.at(10))
        #expect(morning.next?.id == "d")
        #expect(morning.goals.first?.streak == 4)
        #expect(morning.goals.first?.nextCheckIn == Self.at(21))
        // Jueves: el de mañana es de hoy; la racha sigue (ayer hubo avance? no: fue el martes) → 0.
        let thursday = snapshot.day(at: Self.at(6, day: 8), calendar: cal)
        #expect(thursday.reminders.map(\.id) == ["b", "d"])
        #expect(thursday.goals.first?.streak == 0)
        // Sábado: seguimiento entre semana no toca; el próximo es el lunes.
        let saturday = snapshot.day(at: Self.at(12, day: 10), calendar: cal)
        #expect(saturday.checkIns.isEmpty)
        #expect(saturday.goals.first?.nextCheckIn == Self.at(21, day: 12))
        #expect(saturday.reminders.map(\.id) == ["d"])
    }

    @Test func answeredTodayIsNotPendingAndNextFollowUpSkipsToday() {
        let goal = WidgetSnapshot.Goal(id: "g", statement: "Correr",
                                       checkIn: CheckInCadence(cadence: .daily, hour: 20, minute: 0),
                                       streak: 2, lastProgressAt: Self.at(7, 30), lastAnsweredAt: Self.at(7, 30))
        let snapshot = WidgetSnapshot(generatedAt: Self.wednesday8am, selfName: "A", plasticity: 1, nights: 0,
                                      reminders: [], goals: [goal])
        let day = snapshot.day(at: Self.wednesday8am, calendar: Self.calendar)
        #expect(day.checkIns.first?.answered == true)
        #expect(day.pendingCheckIn == nil)
        #expect(day.isEmpty)
        #expect(day.goals.first?.nextCheckIn == Self.at(20, day: 8))
        #expect(day.goal(id: "g")?.statement == "Correr")
        #expect(day.goal(id: "otra") == nil)
    }

    @Test func checkInCadencesProjectToTheirDays() {
        let cal = Self.calendar
        let wednesdayStart = cal.startOfDay(for: Self.wednesday8am)
        let weekly = CheckInCadence(cadence: .weekly, hour: 9, minute: 15, weekday: 4)  // miércoles
        #expect(WidgetSnapshot.checkInTime(weekly, on: wednesdayStart, calendar: cal) == Self.at(9, 15))
        let otherWeekly = CheckInCadence(cadence: .weekly, hour: 9, minute: 15, weekday: 2)
        #expect(WidgetSnapshot.checkInTime(otherWeekly, on: wednesdayStart, calendar: cal) == nil)
        #expect(WidgetSnapshot.checkInTime(.off, on: wednesdayStart, calendar: cal) == nil)
        let invalid = CheckInCadence(cadence: .daily, hour: 30, minute: 0)
        #expect(WidgetSnapshot.checkInTime(invalid, on: wednesdayStart, calendar: cal) == nil)
        #expect(WidgetSnapshot.nextCheckIn(.off, after: Self.wednesday8am, skipToday: false, calendar: cal) == nil)
        #expect(WidgetSnapshot.nextCheckIn(otherWeekly, after: Self.wednesday8am, skipToday: false, calendar: cal)
            == Self.at(9, 15, day: 12))
    }

    @Test func placeholderAndSampleAreSafe() {
        let placeholder = WidgetSnapshot.placeholder(now: Self.wednesday8am)
        #expect(placeholder.day(at: Self.wednesday8am, calendar: Self.calendar).isEmpty)
        let sample = WidgetSnapshot.sample(now: Self.wednesday8am, calendar: Self.calendar)
        let day = sample.day(at: Self.wednesday8am, calendar: Self.calendar)
        #expect(day.next?.text == "Llamar al banco")
        #expect(day.goals.first?.streak == 4)
        #expect(sample.selfName == "Budosky")
    }

    // MARK: - Store + publisher

    @Test func storeRoundTripsAtomicallyAndRejectsGarbage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wsnap-\(UUID().uuidString)")
        let store = WidgetSnapshotStore(directory: dir)
        #expect(store.read() == nil)
        let sample = WidgetSnapshot.sample(now: Self.wednesday8am, calendar: Self.calendar)
        try store.write(sample)
        #expect(store.read() == sample)
        try Data("{no es json".utf8).write(to: store.url)
        #expect(store.read() == nil)
        var future = sample
        future.version = WidgetSnapshot.currentVersion + 1
        try store.write(future)
        #expect(store.read() == nil)
        #expect(WidgetSnapshotStore.shared()?.url.lastPathComponent == WidgetSnapshotStore.fileName
            || WidgetSnapshotStore.shared() == nil)
    }

    @Test func publisherWritesThenReloads() async throws {
        let w = try World()
        _ = try await w.reminders.create(text: "Llamar al banco", fireAt: Self.at(9))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wpub-\(UUID().uuidString)")
        let reloads = Locked(0)
        let publisher = WidgetPublisher(builder: w.builder, store: WidgetSnapshotStore(directory: dir),
                                        reload: { reloads.mutate { $0 += 1 } }, log: { _ in })
        let published = await publisher.publish()
        #expect(published?.reminders.first?.text == "Llamar al banco")
        #expect(WidgetSnapshotStore(directory: dir).read() == published)
        #expect(reloads.value == 1)
    }

    @Test func publisherSurvivesAnUnwritableContainer() async throws {
        let w = try World()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wfile-\(UUID().uuidString)")
        try Data().write(to: file)
        let reloads = Locked(0)
        let logs = Locked<[String]>([])
        let publisher = WidgetPublisher(builder: w.builder, store: WidgetSnapshotStore(directory: file),
                                        reload: { reloads.mutate { $0 += 1 } },
                                        log: { message in logs.mutate { $0.append(message) } })
        #expect(await publisher.publish() == nil)
        #expect(reloads.value == 0)
        #expect(logs.value.count == 1)
    }

    // MARK: - Timeline

    @Test func timelineRefreshesAtEachMomentThatChangesTheWidget() {
        let sample = WidgetSnapshot.sample(now: Self.wednesday8am, calendar: Self.calendar)
        let dates = WidgetTimeline.entryDates(for: sample, from: Self.wednesday8am, calendar: Self.calendar)
        #expect(dates.first == Self.wednesday8am)
        #expect(dates == dates.sorted())
        #expect(dates.contains(Self.at(9)))           // llega el recordatorio
        #expect(dates.contains(Self.at(18, 30)))
        #expect(dates.contains(Self.at(20)))          // seguimiento de hoy
        #expect(dates.contains(Self.at(0, day: 8)))   // medianoche
        #expect(dates.contains(Self.at(8, 15)))       // la hora relativa
        #expect(dates.allSatisfy { $0 <= Self.wednesday8am.addingTimeInterval(24 * 3600) })
        #expect(dates.count <= WidgetTimeline.maxEntries)
    }

    // MARK: - Copy

    @Test func copySpeaksSpanish() {
        let copy = WidgetCopy(calendar: Self.calendar)
        let now = Self.wednesday8am
        #expect(copy.clock(Self.at(9)) == "9:00")
        #expect(copy.clock(Self.at(0, 5)) == "12:05")
        #expect(copy.relative(now.addingTimeInterval(20), now: now) == "ahora")
        #expect(copy.relative(Self.at(8, 25), now: now) == "en 25 min")
        #expect(copy.relative(Self.at(10), now: now) == "en 2 h")
        #expect(copy.relative(Self.at(18, 30), now: now) == "a las 6:30 p. m.")
        #expect(copy.relative(Self.at(7, 50), now: now) == "hace 10 min")
        #expect(copy.relative(Self.at(6), now: now) == "a las 6:00 a. m.")
        #expect(copy.relative(Self.at(9, day: 8), now: now) == "mañana 9:00 a. m.")
        #expect(copy.relative(Self.at(9, day: 6), now: now) == "ayer 9:00 a. m.")
        #expect(copy.streak(0) == "Sin racha aún")
        #expect(copy.streak(1) == "Racha de 1 día")
        #expect(copy.streak(4) == "Racha de 4 días")
        #expect(copy.nights(0) == "Recién nacida")
        #expect(copy.nights(12) == "Noche 12")
        #expect(copy.nextFollowUp(nil, now: now) == "Sin seguimiento")
        #expect(copy.nextFollowUp(Self.at(20), now: now) == "Próximo seguimiento: hoy 8:00 p. m.")
        #expect(WidgetCopy.consolidating("Budosky") == "Budosky está consolidando…")
        #expect(WidgetCopy.nightReady(13) == "Noche #13 lista")
        #expect(WidgetCopy.inline("Llamar al banco") == "llamar al banco")

        let sample = WidgetSnapshot.sample(now: now, calendar: Self.calendar)
        #expect(copy.lockLine(sample.day(at: now, calendar: Self.calendar)) == "Próximo: llamar al banco · 9:00")
        let tomorrowOnly = WidgetSnapshot(generatedAt: now, selfName: "A", plasticity: 1, nights: 0,
                                          reminders: [.init(id: "x", text: "IMSS", fireAt: Self.at(9, day: 8))],
                                          goals: [])
        #expect(copy.lockLine(tomorrowOnly.day(at: now, calendar: Self.calendar))
            == "Próximo: IMSS · mañana 9:00 a. m.")
    }

    // MARK: - Deep links de los widgets

    @Test func widgetDeepLinksRoundTrip() throws {
        let cases: [AnimaDeepLink] = [.talk, .reminders, .goals(id: nil), .goals(id: "g1")]
        for link in cases {
            #expect(AnimaDeepLink.parse(link.url) == link)
        }
        #expect(AnimaDeepLink.talk.url.absoluteString == "anima://chat?mic=1")
        #expect(AnimaDeepLink.reminders.url.absoluteString == "anima://reminders")
        #expect(AnimaDeepLink.parse(try #require(URL(string: "anima://chat?mic=0"))) == .chat(turn: nil))
        #expect(AnimaDeepLink.parse(try #require(URL(string: "anima://goals?id="))) == .goals(id: nil))
    }
}
