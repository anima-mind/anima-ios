import Foundation
import Testing
@testable import AnimaKit

@Suite("Hora de dormir — SleepWindow")
struct SleepWindowTests {
    static func calendar(_ zone: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        return cal
    }

    static let bogota = calendar("America/Bogota")
    static let newYork = calendar("America/New_York")
    static let madrid = calendar("Europe/Madrid")

    static func on(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    static func at(_ cal: Calendar, _ h: Int, _ mi: Int = 0) -> Date { on(cal, 2026, 10, 16, h, mi) }

    static func window(_ sh: Int, _ sm: Int = 0, _ eh: Int, _ em: Int = 0) -> SleepWindow {
        SleepWindow(start: .init(hour: sh, minute: sm), end: .init(hour: eh, minute: em))
    }

    @Test func porDefectoDeUnaASeisDeLaManana() {
        let w = SleepWindow.default
        #expect(w.start == .init(hour: 1) && w.end == .init(hour: 6))
        #expect(w.durationMinutes == 300)
        #expect(w.isValid && !w.crossesMidnight)
        #expect(w.label == "01:00–06:00")
    }

    @Test func inicioIncluidoYFinExcluido() {
        let w = SleepWindow.default
        let cal = Self.bogota
        #expect(w.contains(Self.at(cal, 1, 0), calendar: cal))
        #expect(w.contains(Self.at(cal, 5, 59), calendar: cal))
        #expect(!w.contains(Self.at(cal, 6, 0), calendar: cal))
        #expect(!w.contains(Self.at(cal, 0, 59), calendar: cal))
        #expect(!w.contains(Self.at(cal, 15, 0), calendar: cal), "la tarde no es hora de dormir")
    }

    @Test func cruzaMedianoche() {
        let w = Self.window(23, 0, 5, 0)
        let cal = Self.bogota
        #expect(w.crossesMidnight)
        #expect(w.durationMinutes == 360)
        #expect(w.contains(Self.at(cal, 23, 0), calendar: cal))
        #expect(w.contains(Self.at(cal, 0, 0), calendar: cal))
        #expect(w.contains(Self.at(cal, 4, 59), calendar: cal))
        #expect(!w.contains(Self.at(cal, 5, 0), calendar: cal))
        #expect(!w.contains(Self.at(cal, 22, 59), calendar: cal))
        #expect(!w.contains(Self.at(cal, 12, 0), calendar: cal))
        #expect(w.nextStart(after: Self.at(cal, 22, 0), calendar: cal) == Self.at(cal, 23, 0))
        #expect(w.nextStart(after: Self.at(cal, 2, 0), calendar: cal) == Self.at(cal, 23, 0))
        #expect(w.currentStart(containing: Self.at(cal, 2, 0), calendar: cal) == Self.on(cal, 2026, 10, 15, 23, 0))
        #expect(w.currentStart(containing: Self.at(cal, 23, 30), calendar: cal) == Self.at(cal, 23, 0))
        #expect(w.currentStart(containing: Self.at(cal, 12, 0), calendar: cal) == nil)
    }

    @Test func proximoInicioEsEstrictamentePosterior() {
        let w = SleepWindow.default
        let cal = Self.bogota
        #expect(w.nextStart(after: Self.at(cal, 0, 30), calendar: cal) == Self.at(cal, 1, 0))
        #expect(w.nextStart(after: Self.at(cal, 1, 0), calendar: cal) == Self.on(cal, 2026, 10, 17, 1, 0))
        #expect(w.nextStart(after: Self.at(cal, 15, 0), calendar: cal) == Self.on(cal, 2026, 10, 17, 1, 0))
        #expect(w.currentStart(containing: Self.at(cal, 1, 0), calendar: cal) == Self.at(cal, 1, 0))
        #expect(w.currentStart(containing: Self.at(cal, 3, 0), calendar: cal) == Self.at(cal, 1, 0))
    }

    @Test func dstAdelantaElRelojYElInicioNoExiste() {
        let w = Self.window(2, 0, 6, 0)
        let cal = Self.newYork
        let eve = Self.on(cal, 2026, 3, 7, 22, 0)
        let start = w.nextStart(after: eve, calendar: cal)
        #expect(cal.component(.day, from: start) == 8)
        #expect(cal.component(.hour, from: start) == 3, "02:00 no existe ese día: primera hora válida")
        #expect(w.contains(Self.on(cal, 2026, 3, 8, 3, 30), calendar: cal))
        #expect(!w.contains(Self.on(cal, 2026, 3, 8, 6, 0), calendar: cal))
        #expect(w.currentStart(containing: Self.on(cal, 2026, 3, 8, 4, 0), calendar: cal) == start)
    }

    @Test func dstAtrasaElRelojYElInicioEsLaPrimeraVez() throws {
        let w = SleepWindow.default
        let cal = Self.newYork
        let start = w.nextStart(after: Self.on(cal, 2026, 10, 31, 12, 0), calendar: cal)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(start == utc.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 5)), "01:00 EDT")
        #expect(w.contains(start.addingTimeInterval(3600), calendar: cal), "la 01:00 repetida (EST) sigue dentro")
        #expect(!w.contains(Self.on(cal, 2026, 11, 1, 6, 0), calendar: cal))
    }

    @Test func cambioDeZonaMueveLaVentanaConElRelojDePared() {
        let w = SleepWindow.default
        let instant = Self.at(Self.bogota, 2, 0)
        #expect(w.contains(instant, calendar: Self.bogota))
        #expect(!w.contains(instant, calendar: Self.madrid), "en Madrid son las 09:00")
        #expect(w.nextStart(after: instant, calendar: Self.madrid) == Self.on(Self.madrid, 2026, 10, 17, 1, 0))
        #expect(w.nextStart(after: instant, calendar: Self.bogota) == Self.on(Self.bogota, 2026, 10, 17, 1, 0))
    }

    @Test func rangoValidoEntreUnaYDoceHoras() {
        #expect(Self.window(1, 0, 2, 0).isValid)
        #expect(Self.window(18, 0, 6, 0).isValid)
        #expect(!Self.window(1, 0, 1, 30).isValid)
        #expect(!Self.window(1, 0, 1, 0).isValid)
        #expect(!Self.window(18, 0, 6, 30).isValid)
        #expect(!Self.window(6, 0, 1, 0).isValid, "06→01 son 19 h")
    }

    @Test func horaSeNormaliza() {
        #expect(SleepWindow.Time(minutesOfDay: -60) == .init(hour: 23))
        #expect(SleepWindow.Time(minutesOfDay: 24 * 60 + 90) == .init(hour: 1, minute: 30))
        #expect(SleepWindow.Time(hour: 25, minute: 75) == .init(hour: 23, minute: 59))
        #expect(SleepWindow.Time(hour: -1).minutesOfDay == 0)
        #expect(SleepWindow.Time(hour: 7, minute: 5).label == "07:05")
        #expect(SleepWindow.Time(hour: 1) < SleepWindow.Time(hour: 1, minute: 1))
    }

    // MARK: Preferencia persistida

    static func defaults() -> UserDefaults { UserDefaults(suiteName: "sleep-window-\(UUID().uuidString)")! }

    @Test func preferenciaPersisteYRechazaRangosInvalidos() {
        let ud = Self.defaults()
        let pref = SleepWindowPreference(defaults: ud)
        #expect(pref.window == .default)
        #expect(pref.set(Self.window(23, 0, 5, 30)))
        #expect(SleepWindowPreference(defaults: ud).window == Self.window(23, 0, 5, 30))
        #expect(!pref.set(Self.window(1, 0, 1, 30)))
        #expect(!pref.set(Self.window(8, 0, 21, 0)))
        #expect(pref.window == Self.window(23, 0, 5, 30), "un rango inválido no pisa lo guardado")
    }

    @Test func preferenciaCorruptaCaeAlDefault() {
        let ud = Self.defaults()
        let pref = SleepWindowPreference(defaults: ud)
        ud.set(60, forKey: SleepWindowPreference.startKey)
        #expect(pref.window == .default, "a medias")
        ud.set(2000, forKey: SleepWindowPreference.endKey)
        #expect(pref.window == .default, "fuera del día")
        ud.set(90, forKey: SleepWindowPreference.endKey)
        #expect(pref.window == .default, "dura 30 min")
        ud.set("x", forKey: SleepWindowPreference.endKey)
        #expect(pref.window == .default, "tipo equivocado")
    }
}

@Suite("Hora de dormir — scheduler, runner y fallback")
struct SleepWindowSchedulerTests {
    static let cal = SleepWindowTests.bogota
    static func at(_ h: Int, _ m: Int = 0, day: Int = 16) -> Date { SleepWindowTests.on(cal, 2026, 10, day, h, m) }

    static func scheduler(_ window: SleepWindow = .default, network: Bool = true,
                          now: Date = at(15)) -> SleepScheduler {
        SleepScheduler(requiresNetworkConnectivity: network, window: { window }, calendar: cal, now: { now })
    }

    @Test func submitPideNoEmpezarAntesDelProximoInicio() {
        let plan = Self.scheduler(now: Self.at(15)).request()
        #expect(plan.earliestBeginDate == Self.at(1, day: 17))
        #expect(plan.requiresExternalPower)
        #expect(plan.requiresNetworkConnectivity)
        let local = Self.scheduler(network: false).request(now: Self.at(0, 30))
        #expect(local.earliestBeginDate == Self.at(1))
        #expect(!local.requiresNetworkConnectivity)
        #expect(local.requiresExternalPower)
    }

    @Test func submitDentroDeLaVentanaPuedeEmpezarYa() {
        #expect(Self.scheduler().request(now: Self.at(2)).earliestBeginDate == Self.at(2))
        let crossing = Self.scheduler(SleepWindowTests.window(23, 0, 5, 0))
        #expect(crossing.request(now: Self.at(23, 30)).earliestBeginDate == Self.at(23, 30))
        #expect(crossing.request(now: Self.at(5)).earliestBeginDate == Self.at(23))
    }

    @Test func runnerDentroCorreYFueraDifiere() {
        let s = Self.scheduler()
        #expect(s.launchDecision(now: Self.at(1)) == .run)
        #expect(s.launchDecision(now: Self.at(5, 59)) == .run)
        #expect(s.launchDecision(now: Self.at(6)) == .deferred(until: Self.at(1, day: 17)))
        #expect(s.launchDecision(now: Self.at(16, 20)) == .deferred(until: Self.at(1, day: 17)),
                "cargando en la tarde: no sueña")
        #expect(s.launchDecision(now: Self.at(0, 10)) == .deferred(until: Self.at(1)))
        #expect(Self.scheduler(now: Self.at(3)).launchDecision() == .run, "reloj inyectado")
    }

    @Test func laVentanaSeLeeEnCadaDecision() {
        let current = Locked(SleepWindow.default)
        let s = SleepScheduler(window: { current.value }, calendar: Self.cal, now: { Self.at(23, 30) })
        #expect(s.launchDecision() == .deferred(until: Self.at(1, day: 17)))
        current.mutate { $0 = SleepWindowTests.window(23, 0, 5, 0) }
        #expect(s.launchDecision() == .run)
        #expect(s.request().earliestBeginDate == Self.at(23, 30))
    }

    @Test func porDefectoUsaElCalendarioQueSeActualiza() {
        #expect(SleepScheduler().calendar == Calendar.autoupdatingCurrent)
        #expect(SleepScheduler().window == .default)
    }

    @Test func fallbackFueraDeLaVentanaSoloPasadas48h() {
        let s = Self.scheduler()
        let now = Self.at(15)
        #expect(s.shouldRunForegroundFallback(lastCycleAt: nil, now: now))
        #expect(!s.shouldRunForegroundFallback(lastCycleAt: now.addingTimeInterval(-47 * 3600), now: now))
        #expect(!s.shouldRunForegroundFallback(lastCycleAt: now.addingTimeInterval(-48 * 3600), now: now))
        #expect(s.shouldRunForegroundFallback(lastCycleAt: now.addingTimeInterval(-48 * 3600 - 1), now: now))
    }

    @Test func fallbackDentroDeLaVentanaCorreSiEstaNocheNoHuboCiclo() {
        let s = Self.scheduler()
        let now = Self.at(2)
        #expect(s.shouldRunForegroundFallback(lastCycleAt: Self.at(3, day: 15), now: now), "el último fue anoche")
        #expect(s.shouldRunForegroundFallback(lastCycleAt: Self.at(0, 59), now: now), "antes del inicio de hoy")
        #expect(!s.shouldRunForegroundFallback(lastCycleAt: Self.at(1, 30), now: now), "ya soñó esta noche")
        let crossing = Self.scheduler(SleepWindowTests.window(23, 0, 5, 0))
        #expect(!crossing.shouldRunForegroundFallback(lastCycleAt: Self.at(23, 30, day: 15), now: now))
        #expect(crossing.shouldRunForegroundFallback(lastCycleAt: Self.at(22, 0, day: 15), now: now))
    }

    // MARK: Ajuste → borrador → Listo → persiste → re-encola

    @MainActor
    @Test func lasRuedasNoGuardanHastaListoYElOrdenNaturalFunciona() async {
        let ud = SleepWindowTests.defaults()
        let pref = SleepWindowPreference(defaults: ud)
        let model = SleepWindowSettingsModel(preference: pref, calendar: Self.cal)
        let submitted = Locked<[Date]>([])
        let scheduler = SleepScheduler(window: { pref.window }, calendar: Self.cal, now: { Self.at(15) })
        model.onChanged = { _ in submitted.mutate { $0.append(scheduler.request().earliestBeginDate) } }
        #expect(model.window == .default)

        model.edit(.start)
        for hour in [2, 7, 13, 18, 23] { model.setDraft(.start, .init(hour: hour)) }
        #expect(SleepWindowPreference(defaults: ud).window == .default, "las ruedas no guardan")
        #expect(submitted.value.isEmpty)
        #expect(model.notice == nil, "los valores intermedios no se validan")
        model.edit(.end)
        #expect(model.draftStart == .init(hour: 23), "pasar a Hasta conserva el borrador")
        model.setDraft(.end, .init(hour: 5))
        #expect(await model.commit())
        #expect(model.window == SleepWindowTests.window(23, 0, 5, 0))
        #expect(SleepWindowPreference(defaults: ud).window == model.window)
        #expect(submitted.value == [Self.at(23)])
        #expect(model.editing == nil)
        #expect(model.notice == nil)
    }

    @MainActor
    @Test func listoConUnRangoInvalidoAvisaYConservaLoElegido() async {
        let ud = SleepWindowTests.defaults()
        let pref = SleepWindowPreference(defaults: ud)
        let model = SleepWindowSettingsModel(preference: pref, calendar: Self.cal)
        let calls = Locked(0)
        model.onChanged = { _ in calls.mutate { $0 += 1 } }

        model.edit(.start)
        model.setDraft(.start, .init(hour: 16))
        #expect(await model.commit() == false, "16:00–06:00 son 14 h")
        #expect(model.notice == SleepWindowSettingsModel.invalidNotice)
        #expect(model.editing == .start, "la rueda no se cierra sola")
        #expect(model.draftStart == .init(hour: 16), "no se pierde lo elegido")
        #expect(model.window == .default)
        #expect(SleepWindowPreference(defaults: ud).window == .default)
        model.setDraft(.start, .init(hour: 5, minute: 30))
        #expect(await model.commit() == false, "30 min")
        #expect(calls.value == 0)

        model.edit(.end)
        model.setDraft(.end, .init(hour: 7))
        #expect(await model.commit())
        #expect(model.window == SleepWindowTests.window(5, 30, 7, 0))
        #expect(model.notice == nil)
        #expect(calls.value == 1)

        #expect(await model.commit(), "sin cambios")
        #expect(calls.value == 1)
    }

    @MainActor
    @Test func salirConUnBorradorInvalidoVuelveALoGuardado() async {
        let ud = SleepWindowTests.defaults()
        let model = SleepWindowSettingsModel(preference: SleepWindowPreference(defaults: ud), calendar: Self.cal)
        model.edit(.end)
        model.setDraft(.end, .init(hour: 1))
        #expect(await model.commit() == false)
        model.discardDraft()
        #expect(model.draft == .default)
        #expect(model.editing == nil && model.notice == nil)
        #expect(model.draftTime(.start) == .init(hour: 1) && model.draftTime(.end) == .init(hour: 6))
    }

    @MainActor
    @Test func elAjustePuenteaHorasYFechas() {
        let ud = SleepWindowTests.defaults()
        let pref = SleepWindowPreference(defaults: ud)
        let model = SleepWindowSettingsModel(preference: pref, calendar: Self.cal)
        let date = model.date(for: .init(hour: 23, minute: 15), reference: Self.at(12))
        #expect(date == Self.at(23, 15))
        #expect(model.time(from: date) == .init(hour: 23, minute: 15))
        pref.set(SleepWindowTests.window(0, 0, 4, 0))
        model.refresh()
        #expect(model.window == SleepWindowTests.window(0, 0, 4, 0))
    }
}
