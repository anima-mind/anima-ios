import Foundation
import Testing
@testable import AnimaKit

// Campo batch 5 #11: la card proactiva ya no es texto plano — ícono, etiqueta
// con la hora del aviso, su voz y el seguimiento solo si el aviso ya pasó; y
// sobrevive al relanzar (el turno persiste su marca proactiva).

@Suite struct AnimaDateTextTests {
    typealias F = ProactiveFixtures
    let dates = AnimaDateText(calendar: ProactiveFixtures.calendar)

    @Test func timeIsColombianTwelveHour() {
        #expect(dates.time(F.date(2026, 10, 5, 20, 30)) == "8:30 p. m.")
        #expect(dates.time(F.date(2026, 10, 5, 9, 5)) == "9:05 a. m.")
        #expect(dates.time(F.date(2026, 10, 5, 0, 0)) == "12:00 a. m.")
        #expect(dates.time(F.date(2026, 10, 5, 12, 0)) == "12:00 p. m.")
    }

    @Test func dayHeaderLikeWhatsApp() {
        let now = F.date(2026, 10, 5, 21)
        #expect(dates.dayHeader(F.date(2026, 10, 5, 8), now: now) == "Hoy")
        #expect(dates.dayHeader(F.date(2026, 10, 4, 23), now: now) == "Ayer")
        #expect(dates.dayHeader(F.date(2026, 9, 21, 10), now: now) == "lunes 21 de septiembre")
        #expect(dates.dayHeader(F.date(2025, 12, 31, 10), now: now) == "miércoles 31 de diciembre de 2025")
    }

    @Test func momentSaysWhen() {
        let now = F.date(2026, 10, 5, 14, 30)
        #expect(dates.moment(F.date(2026, 10, 5, 20, 30), now: now) == "hoy 8:30 p. m.")
        #expect(dates.moment(F.date(2026, 10, 6, 9), now: now) == "mañana 9:00 a. m.")
        #expect(dates.moment(F.date(2026, 10, 4, 20, 30), now: now) == "ayer 8:30 p. m.")
        #expect(dates.moment(F.date(2026, 10, 12, 9), now: now) == "lun 12 oct, 9:00 a. m.")
    }
}

@Suite struct ProactiveCardTests {
    typealias F = ProactiveFixtures
    let dates = AnimaDateText(calendar: ProactiveFixtures.calendar)

    @Test func iconsAndLabelsPerKind() {
        let at = F.date(2026, 10, 5, 20, 30)
        let now = F.date(2026, 10, 5, 20, 31)
        #expect(ProactiveCard.symbol(.reminder(id: "r")) == "bell.fill")
        #expect(ProactiveCard.symbol(.checkIn(goalId: "g")) == "target")
        #expect(ProactiveCard.symbol(.intention(id: "i")) == "sparkles")
        #expect(ProactiveCard.label(.reminder(id: "r"), at: at, goalStatement: nil, now: now, dates: dates)
                == "Recordatorio · hoy 8:30 p. m.")
        #expect(ProactiveCard.label(.reminder(id: "r"), at: nil, goalStatement: nil, now: now, dates: dates)
                == "Recordatorio")
        #expect(ProactiveCard.label(.checkIn(goalId: "g"), at: at, goalStatement: "correr", now: now, dates: dates)
                == "Check-in · correr")
        #expect(ProactiveCard.label(.checkIn(goalId: "g"), at: at, goalStatement: nil, now: now, dates: dates)
                == "Check-in")
        #expect(ProactiveCard.label(.intention(id: "i"), at: at, goalStatement: nil, now: now, dates: dates)
                == "Propuesta")
    }

    @Test func followUpOnlyOnceTheReminderIsBehind() {
        let at = F.date(2026, 10, 5, 20, 30)
        #expect(ProactiveCard.followUp(.reminder(id: "r"), at: at, now: at.addingTimeInterval(60)) == nil)
        #expect(ProactiveCard.followUp(.reminder(id: "r"), at: at, now: at.addingTimeInterval(3600)) == "¿Cómo te fue?")
        #expect(ProactiveCard.followUp(.reminder(id: "r"), at: nil, now: at) == nil)
        #expect(ProactiveCard.followUp(.checkIn(goalId: "g"), at: at, now: at.addingTimeInterval(9000)) == nil)
    }

    @Test func tagRoundTripsAndRejectsUnknownKinds() {
        let message = ProactiveMessage(kind: .checkIn(goalId: "g1"), text: "Oye", at: F.start, goalStatement: "correr")
        #expect(ProactiveMessage(tag: message.tag, text: "Oye") == message)
        #expect(ProactiveMessage(tag: ProactiveTag(kind: "bogus", ref: "x"), text: "") == nil)
        #expect(ProactiveMessage.Kind.intention(id: "i").slug == "intention")
        #expect(ProactiveMessage.Kind.intention(id: "i").ref == "i")
    }

    @MainActor
    @Test func historyRepaintsCardsAndLabelsUseTheInjectedClock() async throws {
        let w = try F.world()
        let sid = try w.symbolic.startSession()
        let goalId = await w.other.ingestStated(statement: "invertir 10M", desiredState: .progressCheckIn(everyDays: 2),
                                                evidence: "")
        _ = try await w.reminders.create(text: "cita", message: "Oye, en media hora tienes la cita",
                                         fireAt: F.date(2026, 10, 5, 15))
        try w.symbolic.append(sessionId: sid, message: .user("hola"))
        w.advance(3600)
        _ = await w.reconciler.reconcileDueReminders(sessionId: sid)
        _ = await w.reconciler.checkInPrompt(goalId: goalId, sessionId: sid)

        let loop = AgentLoop(provider: CapturingProvider([]), store: w.symbolic, telemetry: Telemetry(queue: w.queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let chat = ChatViewModel(loop: loop, sessionId: sid)
        chat.dates = dates
        chat.now = { F.date(2026, 10, 5, 16, 30) }
        chat.loadHistory(current: try w.symbolic.visibleTurns(sessionId: sid))
        #expect(chat.messages.map(\.isProactive) == [false, true, true])
        let reminder = chat.messages[1]
        #expect(reminder.proactiveKind == .reminder(id: reminder.reminderId ?? ""))
        #expect(chat.cardLabel(reminder) == "Recordatorio · hoy 3:00 p. m.")
        #expect(chat.cardFollowUp(reminder) == "¿Cómo te fue?")
        let checkIn = chat.messages[2]
        #expect(chat.cardLabel(checkIn) == "Check-in · invertir 10M")
        #expect(chat.cardFollowUp(checkIn) == nil)
        #expect(chat.cardLabel(chat.messages[0]).isEmpty && chat.cardFollowUp(chat.messages[0]) == nil)
    }

    @MainActor
    @Test func repeatingOccurrencesAreNotDeduplicatedAway() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: CapturingProvider([]), store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let chat = ChatViewModel(loop: loop, sessionId: try store.startSession())
        let first = ProactiveMessage(kind: .reminder(id: "r"), text: "Agua", at: F.date(2026, 10, 5, 8))
        var second = first
        second.at = F.date(2026, 10, 6, 8)
        chat.appendProactive([first, first, second])
        #expect(chat.messages.count == 2)
        chat.focus(.reminder(id: "r"))
        #expect(chat.focusedMessageId == chat.messages.last?.id)
        chat.focus(.reminder(id: "missing"))
        #expect(chat.focusedMessageId == chat.messages.last?.id)
    }
}
