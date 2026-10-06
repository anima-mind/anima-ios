import Foundation
import Testing
@testable import AnimaKit

// Batch 5b #1/#6: "jarto que pida aprobar todo el tiempo". Lo interno y
// reversible no pide ok; "Autorizar siempre" persiste y se revoca; rechazar es
// neutral.

@Suite struct ConfirmationPolicyTests {
    static func defaults() throws -> (UserDefaults, String) {
        let suite = "anima.test.permissions.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func internalReversibleActionsSkipTheSheetButTheWorldStillAsks() {
        let policy = PermissionPolicy.app(ownerAllowlist: { [] })
        for op in ["declare", "set_checkin", "clear_checkin", "mark_achieved"] {
            #expect(policy.decide(tool: "goals", known: true, kind: .efferent, operation: op) == .allow)
        }
        for op in ["create", "complete", "cancel", "snooze"] {
            #expect(policy.decide(tool: "anima_reminders", known: true, kind: .efferent, operation: op) == .allow)
        }
        #expect(policy.decide(tool: "calendar", known: true, kind: .efferent, operation: "create") == .ask)
        #expect(policy.decide(tool: "reminders", known: true, kind: .efferent, operation: "create") == .ask)
        #expect(policy.decide(tool: "camera", known: true, kind: .efferent, operation: "capture") == .ask)
        #expect(policy.decide(tool: "goals", known: false, kind: .efferent, operation: "declare") == .deny)
        #expect(PermissionPolicy().decide(tool: "goals", known: true, kind: .efferent, operation: "declare") == .ask)
    }

    @Test func alwaysAllowPersistsAndRevokes() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AuthorizedActionsStore(defaults: defaults)
        let policy = PermissionPolicy.app(ownerAllowlist: { store.entries })
        let entry = AllowlistEntry(tool: "calendar", operation: "create")
        #expect(policy.decide(tool: "calendar", known: true, kind: .efferent, operation: "create") == .ask)
        store.allow(entry)
        #expect(AuthorizedActionsStore(defaults: defaults).entries == [entry])   // persiste
        #expect(policy.decide(tool: "calendar", known: true, kind: .efferent, operation: "create") == .allow)
        #expect(policy.decide(tool: "calendar", known: true, kind: .efferent, operation: "delete") == .ask)
        store.revoke(entry)
        #expect(policy.decide(tool: "calendar", known: true, kind: .efferent, operation: "create") == .ask)
        defaults.set(["roto", "a|b|c"], forKey: AuthorizedActionsStore.key)
        #expect(store.entries == [AllowlistEntry(tool: "a", operation: "b|c")])
    }

    @MainActor
    @Test func centerDecisionsAndTheSettingsModel() async throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AuthorizedActionsStore(defaults: defaults)
        let center = ConfirmationCenter()
        center.onAlwaysAllow = { store.allow(AllowlistEntry(tool: $0.tool, operation: $0.operation)) }
        let request = ConfirmationRequest(tool: "calendar", operation: "create", summary: "Crear evento", input: .null)

        async let first = center.confirm(request)
        while center.pending == nil { await Task.yield() }
        center.resolve(.cancel)
        #expect(await first == false)
        #expect(store.entries.isEmpty)                         // rechazar = neutral

        async let second = center.confirm(request)
        while center.pending == nil { await Task.yield() }
        center.resolve(.always)
        #expect(await second == true)
        #expect(store.entries == [AllowlistEntry(tool: "calendar", operation: "create")])

        async let third = center.confirm(request)
        while center.pending == nil { await Task.yield() }
        center.resolve(true)
        #expect(await third == true)

        let model = AuthorizedActionsModel(store: store)
        #expect(model.entries.count == 1)
        model.revoke(model.entries[0])
        #expect(model.entries.isEmpty && store.entries.isEmpty)
    }

    @Test func friendlyNames() {
        #expect(ToolNames.context(tool: "calendar", operation: "create") == "Calendario del iPhone · crear")
        #expect(ToolNames.context(tool: "reminders", operation: "delete") == "Recordatorios del iPhone · borrar")
        #expect(ToolNames.context(tool: "x", operation: "y") == "x · y")
        for tool in ["notes", "camera", "audio", "phone_context", "glasses_show", "glasses_camera",
                     "anima_reminders", "goals"] {
            #expect(ToolNames.friendly(tool) != tool)
        }
        for op in ["update", "complete", "list", "capture", "show"] {
            #expect(ToolNames.operation(op) != op)
        }
    }
}
