// Sensorimotor.swift — el cuerpo iOS (§5.7): registro de tools, ejecución con
// permisos 2-capas y timeout. Es el punto único por donde pasa toda acción del
// agente sobre el mundo — los permisos los aplica el harness, no el prompt.

import Foundation

/// Una tool del Sensorimotor: además del contrato base (`spec`, `execute`),
/// declara la naturaleza de cada invocación para la PermissionPolicy.
public protocol SensorimotorTool: HarnessTool {
    /// Aferente (lee) o eferente (actúa) según el input concreto.
    func kind(for input: JSONValue) -> ToolKind
    /// Nombre de la operación (para allowlist granular y el diff de confirmación).
    func operation(for input: JSONValue) -> String
    /// Resumen legible de la acción para el `ask` in-chat.
    func confirmationSummary(for input: JSONValue) -> String
}

extension SensorimotorTool {
    public func kind(for input: JSONValue) -> ToolKind { .afferent }
    public func operation(for input: JSONValue) -> String {
        input["action"]?.stringValue ?? "default"
    }
    public func confirmationSummary(for input: JSONValue) -> String {
        "\(spec.name): \(operation(for: input))"
    }
}

public actor Sensorimotor {
    private var tools: [String: any SensorimotorTool]
    private let policy: PermissionPolicy
    private let confirmation: ConfirmationProvider
    private let timeout: TimeInterval

    public init(tools: [any SensorimotorTool] = [],
                policy: PermissionPolicy = .init(),
                confirmation: ConfirmationProvider = FailClosedConfirmation(),
                timeout: TimeInterval = 30) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.spec.name, $0) })
        self.policy = policy
        self.confirmation = confirmation
        self.timeout = timeout
    }

    public func register(_ tool: any SensorimotorTool) {
        tools[tool.spec.name] = tool
    }

    /// Las specs de todas las tools client-side, en orden alfabético estable
    /// (§5.1: jamás reordenar mid-session).
    public func toolSpecs() -> [ToolSpec] {
        tools.values.map(\.spec).sorted { $0.name < $1.name }
    }

    public func has(_ name: String) -> Bool { tools[name] != nil }

    /// Ejecuta una tool aplicando la capa 1 (PermissionPolicy) y un timeout.
    /// Fail-closed: tool desconocida = deny; eferente sin confirmación = no ejecuta.
    public func execute(name: String, input: JSONValue) async -> ToolResult {
        guard let tool = tools[name] else {
            return ToolResult(content: "Tool desconocida o no permitida: \(name)", isError: true)
        }
        let kind = tool.kind(for: input)
        let operation = tool.operation(for: input)

        switch policy.decide(tool: name, known: true, kind: kind, operation: operation) {
        case .deny:
            return ToolResult(content: "Acción no permitida por la política de permisos.", isError: true)
        case .ask:
            let request = ConfirmationRequest(
                tool: name, operation: operation,
                summary: tool.confirmationSummary(for: input), input: input)
            let approved = await confirmation.confirm(request)
            guard approved else {
                return ToolResult(content: "Acción cancelada: el dueño no la confirmó.", isError: true)
            }
        case .allow:
            break
        }

        return await runWithTimeout(tool: tool, input: input)
    }

    private func runWithTimeout(tool: any SensorimotorTool, input: JSONValue) async -> ToolResult {
        await withTaskGroup(of: ToolResult?.self) { group in
            group.addTask { await tool.execute(input) }
            let timeout = self.timeout
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            for await result in group {
                if let result { return result }
                return ToolResult(content: "La tool '\(tool.spec.name)' excedió el timeout de \(Int(self.timeout))s.", isError: true)
            }
            return ToolResult(content: "Sin resultado.", isError: true)
        }
    }
}
