import Foundation
import Testing
import GRDB
@testable import AnimaKit

// Campo (#51): la propuesta del deseo dijo «¿Te gustaría dedicar 715 minutos el
// domingo 18 a las 09:04 para avanzar en tu meta?». El hueco crudo del
// calendario (de ahora, 09:04, a las 21:00 = 715 min) iba al modelo y él lo
// copiaba. Ahora: sesión de ≤1 h en :00/:30, texto validado y duraciones humanas.

@Suite("DurationText — duraciones humanas en español")
struct DurationTextTests {
    @Test func largo() {
        #expect(DurationText.long(minutes: 45) == "45 minutos")
        #expect(DurationText.long(minutes: 1) == "1 minuto")
        #expect(DurationText.long(minutes: 60) == "1 hora")
        #expect(DurationText.long(minutes: 90) == "1 hora y 30 minutos")
        #expect(DurationText.long(minutes: 120) == "2 horas")
        #expect(DurationText.long(minutes: 121) == "2 horas y 1 minuto")
        #expect(DurationText.long(minutes: 715) == "11 horas y 55 minutos")
        #expect(DurationText.long(minutes: 1440) == "1 día")
        #expect(DurationText.long(minutes: 1440 + 180) == "1 día y 3 horas")
        #expect(DurationText.long(minutes: 2 * 1440 + 60) == "2 días y 1 hora")
        #expect(DurationText.long(minutes: 2 * 1440 - 10) == "2 días")
        #expect(DurationText.long(minutes: 0) == "0 minutos")
        #expect(DurationText.long(minutes: -5) == "0 minutos")
    }

    @Test func compacto() {
        #expect(DurationText.compact(minutes: 45) == "45 min")
        #expect(DurationText.compact(minutes: 90) == "1 h 30 min")
        #expect(DurationText.compact(minutes: 120) == "2 h")
        #expect(DurationText.compact(minutes: 715) == "11 h 55 min")
        #expect(DurationText.compact(minutes: 1440) == "1 d")
        #expect(DurationText.compact(minutes: 1440 + 120) == "1 d 2 h")
    }

    @Test func hablado() {
        #expect(DurationText.spoken(minutes: 45) == "45 minutos")
        #expect(DurationText.spoken(minutes: 30) == "media hora")
        #expect(DurationText.spoken(minutes: 1) == "un minuto")
        #expect(DurationText.spoken(minutes: 60) == "una hora")
        #expect(DurationText.spoken(minutes: 90) == "una hora y media")
        #expect(DurationText.spoken(minutes: 61) == "una hora y un minuto")
        #expect(DurationText.spoken(minutes: 150) == "2 horas y media")
        #expect(DurationText.spoken(minutes: 715) == "11 horas y 55 minutos")
        #expect(DurationText.spoken(minutes: 1440) == "un día")
        #expect(DurationText.spoken(minutes: 1500) == "un día y una hora")
        #expect(DurationText.spoken(minutes: 3 * 1440 + 120) == "3 días y 2 horas")
    }

    // Lo que dicen CarPlay y Siri: los minutos crudos se dicen como duración.
    @Test func laVozNoDiceMinutosCrudos() {
        #expect(SiriTurn.plainSpeech("Te propongo 90 min de lectura.") == "Te propongo una hora y media de lectura.")
        #expect(SiriTurn.plainSpeech("Faltan 715 minutos.") == "Faltan 11 horas y 55 minutos.")
        #expect(SiriTurn.plainSpeech("En 10 min sales.") == "En 10 minutos sales.")
        #expect(SiriTurn.plainSpeech("Sin duraciones aquí.") == "Sin duraciones aquí.")
        #expect(SiriTurn.plainSpeech("La minuta está lista.") == "La minuta está lista.")
        #expect(SpokenDurations.apply("Son 5min.") == "Son 5 minutos.")
    }
}

@Suite("ProposalSlot — una sesión razonable desde el hueco libre")
struct ProposalSlotTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Bogota")!
        return c
    }()

    static func at(_ hour: Int, _ minute: Int, _ second: Int = 0, day: Int = 18) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    // El caso del campo: domingo 18, ahora 09:04:30, hueco hasta las 21:00.
    @Test func elCasoDe715MinutosALas0904() throws {
        let now = Self.at(9, 4, 30)
        let raw = DateInterval(start: now, end: Self.at(21, 0))
        #expect(Int(raw.duration / 60) == 715)          // lo que se le pasaba al modelo
        let session = try #require(ProposalSlot.pick(from: [raw], now: now, calendar: Self.calendar))
        #expect(session.start == Self.at(9, 30))
        #expect(session.minutes == 60)
        #expect(session.phrase(calendar: Self.calendar) == "domingo 18 a las 9:30 a. m.")
        #expect(session.summary(calendar: Self.calendar) == "1 hora el domingo 18 a las 9:30 a. m.")
    }

    @Test func redondeaA30MinYRespetaElFinDelHueco() throws {
        let cal = Self.calendar
        #expect(ProposalSlot.roundUp(Self.at(9, 0), calendar: cal) == Self.at(9, 0))
        #expect(ProposalSlot.roundUp(Self.at(9, 0, 1), calendar: cal) == Self.at(9, 30))
        #expect(ProposalSlot.roundUp(Self.at(9, 31), calendar: cal) == Self.at(10, 0))
        #expect(ProposalSlot.roundUp(Self.at(23, 45), calendar: cal) == Self.at(0, 0, day: 19))
        // Hueco corto: 45 min desde las 15:10 → arranca 15:30 y quedan 25: no cabe; sigue el próximo.
        let short = DateInterval(start: Self.at(15, 10), end: Self.at(15, 55))
        let next = DateInterval(start: Self.at(17, 0), end: Self.at(17, 45))
        let session = try #require(ProposalSlot.pick(from: [next, short], now: Self.at(8, 0), calendar: cal))
        #expect(session.start == Self.at(17, 0))
        #expect(session.minutes == 45)
        #expect(ProposalSlot.pick(from: [short], now: Self.at(8, 0), calendar: cal) == nil)
        #expect(ProposalSlot.pick(from: [], now: Self.at(8, 0), calendar: cal) == nil)
    }

    @Test func validaElTextoDelModelo() {
        // Cifras absurdas o la hora suelta del hueco crudo: no pasan.
        #expect(ProposalText.validated("¿Te gustaría dedicar 715 minutos el domingo 18 a las 09:04 para avanzar en tu meta?") == nil)
        #expect(ProposalText.validated("¿Dedicamos 12 horas a la tesis?") == nil)
        #expect(ProposalText.validated("¿Lo hacemos a las 09:04?") == nil)
        #expect(ProposalText.validated("¿Te parece 0 minutos?") == nil)
        // Control: una propuesta razonable pasa, con la duración en formato humano.
        #expect(ProposalText.validated("¿Dedicamos 90 minutos el domingo a las 09:30 a la tesis?")
                == "¿Dedicamos 1 hora y 30 minutos el domingo a las 09:30 a la tesis?")
        #expect(ProposalText.validated("¿Le damos 1 hora a la tesis?") == "¿Le damos 1 hora a la tesis?")
        #expect(ProposalText.validated("¿Le damos 2 h a la tesis?") == "¿Le damos 2 horas a la tesis?")
        #expect(ProposalText.validated("¿Retomamos la tesis hoy?") == "¿Retomamos la tesis hoy?")
    }
}

@Suite("DesireEngine — la propuesta del caso 715 / 09:04")
struct DesireProposalDurationTests {
    static func events(_ text: String) -> [ProviderEvent] {
        [.messageStart(id: "t", model: "claude-haiku-4-5"), .textDelta(text), .blockStop(index: 0),
         .messageDelta(stopReason: .endTurn, usage: Usage()), .messageStop]
    }

    private func pulse(modelSays text: String) async throws -> (Intention?, String) {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 9, minute: 4, second: 30))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 21))!
        let queue = try AnimaDatabase.temporary()
        let other = OtherModel(queue: queue, now: { now })
        _ = await other.ingestStated(statement: "Escribir la tesis", desiredState: .workoutsPerWeek(atLeast: 3),
                                     evidence: "\"quiero avanzar la tesis\"", priority: 7)
        let provider = CapturingProvider([Self.events(text)])
        let env = MockObservableEnvironment(workouts: 0, slots: [DateInterval(start: now, end: end)])
        let engine = DesireEngine(otherModel: other, environment: env, queue: queue, provider: provider,
                                  router: try .haikuAll(), authMode: .apiKey, token: "sk-ant-api03-x",
                                  now: { now })
        let produced = try await engine.pulse()
        let prompt = provider.captures.value.first?.messages.first?.content.compactMap { block -> String? in
            if case .text(let t) = block { return t } else { return nil }
        }.joined() ?? ""
        return (produced.first, prompt)
    }

    @Test func elModeloCopiaElHuecoCrudoYSeReemplaza() async throws {
        let (intention, prompt) = try await pulse(
            modelSays: "¿Te gustaría dedicar 715 minutos el domingo 18 a las 09:04 para avanzar en tu meta?")
        let text = try #require(intention?.proposedText)
        #expect(!text.contains("715"))
        #expect(!text.contains("09:04"))
        #expect(text == "¿Te parece dedicar 1 hora el domingo 18 a las 9:30 a. m. a avanzar en 'Escribir la tesis'?")
        // Al modelo ya no le llega el hueco crudo.
        #expect(prompt.contains("domingo 18 a las 9:30 a. m., una sesión de 1 hora"))
        #expect(!prompt.contains("715"))
        #expect(!prompt.contains("09:04"))
    }

    // Control negativo: una propuesta sensata del modelo se respeta (con duraciones humanas).
    @Test func unaPropuestaSensataSeRespeta() async throws {
        let (intention, _) = try await pulse(modelSays: "¿Le dedicamos 60 minutos a la tesis a las 9:30 a. m.?")
        #expect(intention?.proposedText == "¿Le dedicamos 1 hora a la tesis a las 9:30 a. m.?")
    }
}
