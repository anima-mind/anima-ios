import Foundation
import Testing
@testable import AnimaKit

// Campo batch 5 #7: "no se ve la hora ni fecha; si es el mismo día solo hora,
// si es día previo la fecha también, como WhatsApp".

@MainActor
@Suite struct ChatTimestampsTests {
    typealias F = ProactiveFixtures
    let dates = AnimaDateText(calendar: ProactiveFixtures.calendar)

    private func message(_ text: String, at date: Date, divider: Bool = false) -> ChatViewModel.DisplayMessage {
        var m = ChatViewModel.DisplayMessage(role: .user, text: text, isSessionDivider: divider)
        m.sentAt = date
        return m
    }

    @Test func separatorsBeforeTheFirstMessageOfEachDay() {
        let now = F.date(2026, 10, 5, 21)
        let old = message("hace dos semanas", at: F.date(2026, 9, 21, 10))
        let y1 = message("ayer 1", at: F.date(2026, 10, 4, 9))
        let y2 = message("ayer 2", at: F.date(2026, 10, 4, 22))
        let divider = message(ChatViewModel.sessionDividerText, at: F.date(2026, 10, 5, 7), divider: true)
        let t1 = message("hoy", at: F.date(2026, 10, 5, 8))
        let headers = ChatViewModel.dayHeaders([old, y1, y2, divider, t1], now: now, dates: dates)
        #expect(headers == [old.id: "lunes 21 de septiembre", y1.id: "Ayer", t1.id: "Hoy"])
        #expect(ChatViewModel.dayHeaders([], now: now, dates: dates).isEmpty)
    }

    @Test func historyCarriesTheTurnTimeAndTheBubbleShowsIt() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let sid = try store.startSession()
        try store.append(sessionId: sid, message: .user("hola"))
        let turns = try store.visibleTurns(sessionId: sid)
        let created = try #require(turns.first?.createdAt)
        #expect(abs(created.timeIntervalSinceNow) < 5)

        let loop = AgentLoop(provider: CapturingProvider([]), store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        let chat = ChatViewModel(loop: loop, sessionId: sid)
        chat.dates = dates
        chat.now = { F.date(2026, 10, 5, 21) }
        let past = VisibleTurn(role: .assistant, text: "listo", createdAt: F.date(2026, 10, 5, 20, 30))
        chat.loadHistory(current: [past])
        #expect(chat.timeLabel(chat.messages[0]) == "8:30 p. m.")
        #expect(chat.dayHeaders() == [chat.messages[0].id: "Hoy"])

        chat.input = "otra"
        await chat.send()
        let sent = try #require(chat.messages.first { $0.role == .user })
        // Reloj real (no el inyectado de los rótulos); holgura para runners de CI lentos.
        #expect(abs(sent.sentAt.timeIntervalSinceNow) < 15)
    }
}
