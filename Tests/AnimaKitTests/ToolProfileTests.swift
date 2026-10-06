import Foundation
import Testing
@testable import AnimaKit

// El modelo de Apple tiene 4096 tokens: el registro completo de tools costaba
// 3797 (medido). El perfil local manda solo lo útil en Solo teléfono, mínimo.

@Suite struct ToolProfileTests {
    static let measuredFullRegistryTokens = 3797
    static let onDeviceToolCeiling = 1400
    static let onDeviceRoomFloor = 2000

    /// El system prompt bundled del modelo local + el mapa corto de la app.
    static func onDeviceSystemBase() throws -> String {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../App/RemoteConfigDefaults.plist").standardizedFileURL
        let dict = try #require(NSDictionary(contentsOf: plist))
        let base = try #require(dict[ProviderConfigParser.promptKey(for: .onDevice)] as? String)
        return AppGuide.systemBase(base, contextBudget: ContextProfile.onDevice.contextBudgetTokens)
    }

    @Test func profilePerProvider() throws {
        let tools = try RealToolSet.specs()
        let server: ToolSpec = .server(type: "web_search_20260209", name: "web_search")
        #expect(ToolProfile.for(model: OnDeviceProvider.modelName) == .onDevice)
        #expect(ToolProfile.for(model: "claude-opus-4-8") == .full)
        #expect(ToolProfile.for(model: "gpt-5.2") == .full)
        #expect(ToolProfile.full.apply(tools + [server]) == tools + [server])

        let local = ToolProfile.onDevice.apply(tools + [server])
        #expect(Set(local.map(\.name)) == ["anima_reminders", "goals", "calendar", "reminders", "notes"])
        #expect(ToolProfile.onDevice.apply(local) == local)
        for name in ToolProfile.excludedOnDevice { #expect(!local.contains { $0.name == name }) }
    }

    @Test func unknownToolNeverReachesTheLocalModel() throws {
        let custom: ToolSpec = .client(name: "nueva_tool", description: String(repeating: "x", count: 4000),
                                       inputSchema: .object(["type": .string("object")]))
        #expect(ToolProfile.onDevice.apply([custom]).isEmpty)
        #expect(ToolProfile.full.apply([custom]) == [custom])
        let request = OnDevicePromptBuilder.request(ctx: AssembledContext(messages: [.user("hola")]),
                                                    tools: [custom, CalendarTool().spec],
                                                    opts: try OnDeviceTestConfig.opts())
        #expect(request.tools.map(\.name) == ["calendar"])
    }

    @Test func compactGuideSaysWhatTheLocalModelCannotDo() {
        for missing in ["cámara", "fotos", "audio", "gafas", "contexto del teléfono"] {
            #expect(AppGuide.compactBlock.contains(missing), "falta \(missing)")
        }
    }

    /// Documentación: cada tool del registro tiene decisión explícita en local.
    @Test func everyRegisteredToolHasALocalDecision() throws {
        for spec in try RealToolSet.specs() {
            #expect(ToolProfile.compact[spec.name] != nil || ToolProfile.excludedOnDevice.contains(spec.name),
                    "\(spec.name) sin decisión para el modelo local")
        }
    }

    /// Una línea ≤ 120, sin enums (pistas de campo ≤ 30), y los mismos nombres
    /// de parámetro que el schema completo (la ejecución no cambia).
    @Test func compactSpecsAreMinimalAndCompatible() throws {
        let full = Dictionary(uniqueKeysWithValues: try RealToolSet.specs().map { ($0.name, $0) })
        for (name, spec) in ToolProfile.compact {
            guard case .client(_, let description, let schema) = spec,
                  case .client(_, _, let fullSchema)? = full[name] else {
                Issue.record("\(name) no está en el registro"); continue
            }
            #expect(description.count <= 120 && !description.contains("\n"), "\(name): \(description.count)")
            let props = schema["properties"]?.objectValue ?? [:]
            let fullProps = fullSchema["properties"]?.objectValue ?? [:]
            #expect(props["action"] != nil)
            for (key, value) in props {
                #expect(fullProps[key] != nil, "\(name).\(key) no existe en el schema completo")
                #expect(value["type"] == fullProps[key]?["type"], "\(name).\(key) cambió de tipo")
                #expect(value["enum"] == nil)
                #expect((value["description"]?.stringValue?.count ?? 0) <= 30, "\(name).\(key): pista larga")
            }
        }
    }

    /// Los vocabularios cerrados que el perfil quitó como enum siguen visibles.
    @Test func closedVocabulariesSurviveWithoutEnums() throws {
        func text(_ name: String) throws -> String {
            guard case .client(_, let description, let schema)? = ToolProfile.compact[name],
                  let data = try? JSONEncoder().encode(schema) else { throw ProfileError.missing(name) }
            return description + " " + String(decoding: data, as: UTF8.self)
        }
        let reminders = try text("anima_reminders")
        for value in ProactiveCadence.allCases.map(\.rawValue) + ["list", "create", "complete", "cancel", "snooze"] {
            #expect(reminders.contains(value), "anima_reminders sin \(value)")
        }
        #expect(reminders.contains("fire_at ISO 8601"))
        let goals = try text("goals")
        for value in ProactiveCadence.allCases.map(\.rawValue) + CheckInAnswer.allCases.map(\.rawValue)
            + ["0-23", "1-7", "list", "declare", "set_checkin", "clear_checkin", "record_checkin", "mark_achieved"] {
            #expect(goals.contains(value), "goals sin \(value)")
        }
    }

    enum ProfileError: Error { case missing(String) }

    @Test func onDeviceProfileFitsTheMeasuredBudget() async throws {
        let tools = try RealToolSet.specs()
        let local = ToolProfile.onDevice.apply(tools)
        let estimate = ContextBudget.onDevice.toolTokens(tools)
        #expect(estimate <= Self.onDeviceToolCeiling, "estimado \(estimate)")
        if let real = await RealToolSet.frameworkTokenCount(local) {
            print("[tool-profile] tokenizer real: perfil local \(real) tokens; estimado \(estimate)")
            #expect(real <= Self.onDeviceToolCeiling, "real \(real)")
            #expect(abs(estimate - real) <= max(real / 5, 60), "estimado \(estimate) vs real \(real)")
        }
        if let fullReal = await RealToolSet.frameworkTokenCount(tools) {
            #expect(abs(fullReal - Self.measuredFullRegistryTokens) <= Self.measuredFullRegistryTokens / 10)
        }

        let systemBase = try Self.onDeviceSystemBase()
        let room = ContextProfile.onDevice.contextBudgetTokens
            - ContextBudget.onDevice.fixedTokens(systemBase: systemBase, tools: tools)
        #expect(room >= Self.onDeviceRoomFloor, "quedan \(room)")
    }

    @Test func onDeviceProviderSendsTheCompactProfile() throws {
        let tools = try RealToolSet.specs()
        let request = OnDevicePromptBuilder.request(ctx: AssembledContext(messages: [.user("hola")]), tools: tools,
                                                    opts: try OnDeviceTestConfig.opts())
        #expect(request.tools.map(\.name).sorted() == ToolProfile.onDevice.apply(tools).map(\.name).sorted())
        let reminders = try #require(request.tools.first { $0.name == "anima_reminders" })
        guard case .object(_, _, let properties) = reminders.schema else { Issue.record("sin objeto"); return }
        #expect(properties.allSatisfy { $0.description == nil })
        #expect(properties.allSatisfy { if case .string(_, let choices) = $0.schema { choices == nil } else { true } })
    }
}
