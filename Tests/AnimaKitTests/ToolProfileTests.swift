import Foundation
import Testing
@testable import AnimaKit

// El modelo de Apple tiene 4096 tokens: el registro completo de tools costaba
// 3797 (medido). El set local del adapter: una intención por tool, todo
// obligatorio, un ejemplo literal.

@Suite struct ToolProfileTests {
    static let measuredFullRegistryTokens = 3797
    static let onDeviceToolCeiling = 900
    static let onDeviceSystemCeiling = 1500
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
        #expect(local.map(\.name) == ["remind_me", "list_reminders", "declare_goal", "list_goals",
                                      "add_calendar_event", "list_events", "write_note", "read_note"])
        #expect(ToolProfile.onDevice.apply(local) == local)
        for name in ToolProfile.excludedOnDevice { #expect(!local.contains { $0.name == name }) }
    }

    @Test func onlyToolsWhoseRealToolIsRegisteredTravel() throws {
        let custom: ToolSpec = .client(name: "nueva_tool", description: String(repeating: "x", count: 4000),
                                       inputSchema: .object(["type": .string("object")]))
        #expect(ToolProfile.onDevice.apply([custom]).isEmpty)
        #expect(ToolProfile.full.apply([custom]) == [custom])
        let request = OnDevicePromptBuilder.request(ctx: AssembledContext(messages: [.user("hola")]),
                                                    tools: [custom, CalendarTool().spec],
                                                    opts: try OnDeviceTestConfig.opts())
        #expect(request.tools.map(\.name) == ["add_calendar_event", "list_events"])
    }

    @Test func compactGuideSaysWhatTheLocalModelCannotDo() {
        for missing in ["cámara", "fotos", "audio", "gafas", "contexto del teléfono"] {
            #expect(AppGuide.compactBlock.contains(missing), "falta \(missing)")
        }
    }

    /// Documentación: cada tool del registro tiene decisión explícita en local.
    @Test func everyRegisteredToolHasALocalDecision() throws {
        for spec in try RealToolSet.specs() {
            #expect(LocalToolAdapter.realTools.contains(spec.name) || ToolProfile.excludedOnDevice.contains(spec.name),
                    "\(spec.name) sin decisión para el modelo local")
        }
        #expect(LocalToolAdapter.realTools.isDisjoint(with: ToolProfile.excludedOnDevice))
    }

    /// Una intención por tool: ≤ 3 parámetros, todos obligatorios, una línea con
    /// un ejemplo literal (salvo la que no lleva parámetros).
    @Test func localToolsAreSingleIntentAndAllRequired() throws {
        for tool in LocalToolAdapter.tools {
            guard case .client(let name, let description, let schema) = tool.spec else {
                Issue.record("\(tool.name) no es client"); continue
            }
            let props = schema["properties"]?.objectValue ?? [:]
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            #expect(props.count <= 3, "\(name): \(props.count) parámetros")
            #expect(Set(props.keys) == required, "\(name): no todo es obligatorio")
            #expect(props["action"] == nil)
            #expect(description.count <= 150 && !description.contains("\n"), "\(name): \(description.count)")
            if !props.isEmpty {
                #expect(description.contains("Ej: " + tool.example), "\(name) sin ejemplo literal")
            }
            #expect(name.allSatisfy { $0.isASCII && ($0.isLowercase || $0 == "_") })
        }
    }

    @Test func onDeviceProfileFitsTheMeasuredBudget() async throws {
        let tools = try RealToolSet.specs()
        let local = ToolProfile.onDevice.apply(tools)
        let estimate = ContextBudget.onDevice.toolTokens(tools)
        #expect(estimate <= Self.onDeviceToolCeiling, "estimado \(estimate)")
        if let real = await RealToolSet.frameworkTokenCount(local) {
            print("[tool-profile] tokenizer real: set local \(real) tokens; estimado \(estimate)")
            #expect(real <= Self.onDeviceToolCeiling, "real \(real)")
            #expect(abs(estimate - real) <= max(real / 5, 60), "estimado \(estimate) vs real \(real)")
        }
        if let fullReal = await RealToolSet.frameworkTokenCount(tools) {
            #expect(abs(fullReal - Self.measuredFullRegistryTokens) <= Self.measuredFullRegistryTokens / 10)
        }

        // System local completo: identidad + reglas + guía + reloj/semana + tools.
        let systemBase = try Self.onDeviceSystemBase()
        let now = Date(timeIntervalSince1970: 1_791_300_600)
        let clock = WorkingMemory.clockLine(for: now, timeZone: .current) + "\n"
            + WorkingMemory.weekLine(for: now, timeZone: .current)
        let fixed = ContextBudget.onDevice.fixedTokens(systemBase: systemBase + "\n\n" + clock, tools: tools)
        #expect(fixed <= Self.onDeviceSystemCeiling, "system local \(fixed)")
        if let instructions = await RealToolSet.frameworkInstructionTokens(systemBase + "\n\n" + clock),
           let toolsReal = await RealToolSet.frameworkTokenCount(local) {
            print("[tool-profile] tokenizer real: system \(instructions) + tools \(toolsReal) = \(instructions + toolsReal); "
                  + "libres \(ContextProfile.onDevice.contextBudgetTokens - instructions - toolsReal)")
            #expect(instructions + toolsReal <= Self.onDeviceSystemCeiling)
            #expect(ContextProfile.onDevice.contextBudgetTokens - instructions - toolsReal >= Self.onDeviceRoomFloor)
        }
        let room = ContextProfile.onDevice.contextBudgetTokens - fixed
        #expect(room >= Self.onDeviceRoomFloor, "quedan \(room)")
    }

    /// D: reglas del modelo local en código (Remote Config no las puede quitar).
    @Test func localRulesTravelWithTheCompactGuide() throws {
        let base = try Self.onDeviceSystemBase()
        #expect(base.hasPrefix("Eres Anima"))
        #expect(base.contains(AppGuide.localRules) && base.contains(AppGuide.compactBlock))
        for rule in ["de tú", "1-3 frases", "placeholders", "Nunca digas que hiciste algo", "si falla, dilo"] {
            #expect(AppGuide.localRules.contains(rule), "falta \(rule)")
        }
        #expect(!AppGuide.systemBase("B").contains(AppGuide.localRules))
    }

    @Test func onDeviceProviderSendsTheLocalSet() throws {
        let tools = try RealToolSet.specs()
        let request = OnDevicePromptBuilder.request(ctx: AssembledContext(messages: [.user("hola")]), tools: tools,
                                                    opts: try OnDeviceTestConfig.opts())
        #expect(request.tools.map(\.name) == ToolProfile.onDevice.apply(tools).map(\.name))
        let remind = try #require(request.tools.first { $0.name == "remind_me" })
        guard case .object(_, _, let properties) = remind.schema else { Issue.record("sin objeto"); return }
        #expect(properties.allSatisfy { !$0.isOptional })
        let byName = Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.schema) })
        #expect(byName["when"] == .patterned(description: nil, pattern: LocalToolAdapter.datePattern))
        // Sin enum: con anyOf el 3B elegía "daily" para "mañana a las 9" (medido);
        // el adapter normaliza el texto libre.
        #expect(byName["repeat"] == .string(description: nil, choices: nil))
        let goal = try #require(request.tools.first { $0.name == "declare_goal" })
        guard case .object(_, _, let goalProps) = goal.schema else { Issue.record("sin objeto"); return }
        #expect(goalProps.first { $0.name == "hour" }?.schema == .bounded(description: nil, range: 0...23))
    }
}
