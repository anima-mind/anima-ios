import Foundation
import Testing
@testable import AnimaKit

// Nunca mentir tras un error. Medido con el modelo de Apple: tras
// un error de tool respondía "He programado un recordatorio…".

@Suite struct ToolFailureNoticeTests {

    @Test func aLieAfterAToolErrorGetsTheNoticeInFront() async throws {
        let root = LocalLoopHarness.notesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "notes", #"{"action":"read","name":"diario"}"#),
            LocalLoopHarness.text("Listo, aquí está tu nota del diario."),
        ], tools: [NotesTool(root: root)])
        let notice = "⚠️ No pude leer la nota: La nota 'diario' no existe."
        #expect(r.notice == notice)
        #expect(try r.lastAssistantText() == notice + "\n\nListo, aquí está tu nota del diario.")
        #expect(r.events.contains(.assistantMessage([.text(notice + "\n\nListo, aquí está tu nota del diario.")])))
    }

    @Test func anAdmissionIsNotDuplicated() async throws {
        let root = LocalLoopHarness.notesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "notes", #"{"action":"read","name":"diario"}"#),
            LocalLoopHarness.text("No pude leer esa nota: no existe."),
        ], tools: [NotesTool(root: root)])
        #expect(r.notice == nil)
        #expect(try r.lastAssistantText() == "No pude leer esa nota: no existe.")
    }

    @Test func aLaterSuccessOfTheSameIntentClearsTheFailure() async throws {
        let root = LocalLoopHarness.notesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await NotesTool(root: root).execute(.object([
            "action": .string("create"), "name": .string("diario"), "content": .string("hoy corrí")]))
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "notes", #"{"action":"read","name":"diaro"}"#),
            LocalLoopHarness.toolUse("b", "notes", #"{"action":"read","name":"diario"}"#),
            LocalLoopHarness.text("Tu diario dice: hoy corrí."),
        ], tools: [NotesTool(root: root)])
        #expect(r.notice == nil)
        #expect(r.text == "Tu diario dice: hoy corrí.")
    }

    @Test func anOwnerRejectionCannotBeReportedAsDone() async throws {
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "calendar", #"{"action":"create","title":"x","start":"2030-01-01T09:00:00"}"#),
            LocalLoopHarness.text("Listo, quedó en tu agenda."),
        ], tools: [CalendarTool(makeStore: { MockCalendarStore() })])
        #expect(r.events.contains(.toolFinished(name: "calendar", isError: true)))
        #expect(r.notice == "⚠️ No pude crear el evento: no lo confirmaste.")
    }

    @Test func aDifferentIntentKeepsTheFailureVisible() async throws {
        let root = LocalLoopHarness.notesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try await LocalLoopHarness.run([
            LocalLoopHarness.toolUse("a", "notes", #"{"action":"read","name":"diario"}"#),
            LocalLoopHarness.toolUse("b", "notes", #"{"action":"create","name":"otra","content":"x"}"#),
            LocalLoopHarness.text("Hecho."),
        ], tools: [NotesTool(root: root)])
        #expect(r.notice == "⚠️ No pude leer la nota: La nota 'diario' no existe.")
    }

    @MainActor
    @Test func theChatCardIsMarkedAndHistoryKeepsTheMark() async throws {
        let root = LocalLoopHarness.notesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: ScriptedProvider([
            LocalLoopHarness.toolUse("a", "notes", #"{"action":"read","name":"diario"}"#),
            LocalLoopHarness.text("Aquí está tu nota."),
        ]), store: store, telemetry: Telemetry(queue: queue), router: ModelRouter(config: try TestConfig.providerConfig()),
            authMode: .apiKey, token: "sk-ant-api03-x", clientTools: [NotesTool(root: root)], serverTools: [],
            sleep: { _ in })
        let sid = try store.startSession()
        let chat = ChatViewModel(loop: loop, sessionId: sid)
        chat.input = "lee mi diario"
        await chat.send()
        let last = try #require(chat.messages.last)
        #expect(last.toolFailure)
        #expect(last.text == "⚠️ No pude leer la nota: La nota 'diario' no existe.\n\nAquí está tu nota.")
        let history = ChatViewModel.history(current: try store.visibleTurns(sessionId: sid))
        #expect(history.last?.toolFailure == true)
        #expect(history.first?.toolFailure == false)
    }
}

