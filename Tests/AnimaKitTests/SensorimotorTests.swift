import Foundation
import Testing
@testable import AnimaKit

// MARK: - Dobles de prueba

/// Tool eferente que registra si su execute llegó a correr.
final class SpyEfferentTool: SensorimotorTool, @unchecked Sendable {
    let executed = Locked(false)
    var spec: ToolSpec {
        .client(name: "spy", description: "spy", inputSchema: .object(["type": .string("object")]))
    }
    func kind(for input: JSONValue) -> ToolKind { .efferent }
    func operation(for input: JSONValue) -> String { "write" }
    func execute(_ input: JSONValue) async -> ToolResult {
        executed.mutate { $0 = true }
        return ToolResult(content: "hecho")
    }
}

struct ApproveAll: ConfirmationProvider {
    func confirm(_ request: ConfirmationRequest) async -> Bool { true }
}

@Suite struct PermissionPolicyTests {

    @Test func unknownToolIsDeniedFailClosed() {
        let policy = PermissionPolicy()
        #expect(policy.decide(tool: "ghost", known: false, kind: .afferent, operation: nil) == .deny)
    }

    @Test func afferentAllowsEfferentAsks() {
        let policy = PermissionPolicy()
        #expect(policy.decide(tool: "calendar", known: true, kind: .afferent, operation: "list") == .allow)
        #expect(policy.decide(tool: "calendar", known: true, kind: .efferent, operation: "create") == .ask)
    }

    @Test func allowlistPromotesEfferentToAllow() {
        let policy = PermissionPolicy(allowlist: [AllowlistEntry(tool: "calendar", operation: "create")])
        #expect(policy.decide(tool: "calendar", known: true, kind: .efferent, operation: "create") == .allow)
        #expect(policy.decide(tool: "calendar", known: true, kind: .efferent, operation: "delete") == .ask)
    }
}

@Suite struct SensorimotorTests {

    @Test func unknownToolDenied() async {
        let sensorimotor = Sensorimotor(tools: [])
        let result = await sensorimotor.execute(name: "ghost", input: .object([:]))
        #expect(result.isError)
    }

    /// Eferente sin confirmación (FailClosed) NO ejecuta la tool.
    @Test func efferentWithoutConfirmationDoesNotExecute() async {
        let spy = SpyEfferentTool()
        let sensorimotor = Sensorimotor(tools: [spy], confirmation: FailClosedConfirmation())
        let result = await sensorimotor.execute(name: "spy", input: .object([:]))
        #expect(result.isError)
        #expect(spy.executed.value == false)
    }

    /// Con confirmación aprobada, el eferente sí ejecuta.
    @Test func efferentWithApprovalExecutes() async {
        let spy = SpyEfferentTool()
        let sensorimotor = Sensorimotor(tools: [spy], confirmation: ApproveAll())
        let result = await sensorimotor.execute(name: "spy", input: .object([:]))
        #expect(!result.isError)
        #expect(spy.executed.value == true)
    }

    /// NotesTool (aferente, su propia libreta) ejecuta sin confirmación.
    @Test func notesRunsWithoutConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sensorimotor = Sensorimotor(tools: [NotesTool(root: root)], confirmation: FailClosedConfirmation())
        let result = await sensorimotor.execute(
            name: "notes",
            input: .object(["action": .string("create"), "name": .string("x"), "content": .string("hola")]))
        #expect(!result.isError)
    }
}
