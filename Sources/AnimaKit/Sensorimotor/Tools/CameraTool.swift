// CameraTool.swift — contrato de la tool `camera` (§5.7). La CAPTURA en sí es UI
// de iOS (#if os(iOS), va en UI/); aquí vive el contrato + el pipeline puro
// (ImageDownscaler). Regla dura de captura (§8): el agente nunca captura en
// silencio — la tool es .efferent para forzar `ask` aunque perceptualmente sea
// aferente.

import Foundation

public struct CameraTool: SensorimotorTool {
    /// La UI de iOS inyecta la captura real; devuelve los bytes de la imagen.
    public typealias Capture = @Sendable () async -> Data?
    private let capture: Capture?

    public init(capture: Capture? = nil) {
        self.capture = capture
    }

    public var spec: ToolSpec {
        .client(
            name: "camera",
            description: """
                Solicita al dueño una foto con la cámara del teléfono. Requiere su \
                confirmación (nunca captura en silencio). La imagen se adjunta \
                (JPEG, lado largo ≤1568px) al contexto para que la puedas describir \
                o analizar. Úsala cuando necesites ver algo del entorno físico del dueño.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "reason": .object([
                        "type": .string("string"),
                        "description": .string("Para qué necesitas la foto (se le muestra al dueño)."),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]))
    }

    // Perceptualmente aferente, pero la regla de captura la fuerza a `ask`.
    public func kind(for input: JSONValue) -> ToolKind { .efferent }
    public func operation(for input: JSONValue) -> String { "capture_photo" }
    public func confirmationSummary(for input: JSONValue) -> String {
        let reason = input["reason"]?.stringValue ?? "sin motivo indicado"
        return "Tomar una foto con la cámara (\(reason))"
    }

    public func execute(_ input: JSONValue) async -> ToolResult {
        guard let capture else {
            return ToolResult(content: "La captura de cámara la inicia el dueño desde la app.")
        }
        guard let data = await capture() else {
            return ToolResult(content: "No se capturó ninguna imagen.", isError: true)
        }
        guard let output = ImageDownscaler.process(data) else {
            return ToolResult(content: "La imagen capturada no pudo procesarse.", isError: true)
        }
        return ToolResult(content: "Foto capturada y adjuntada (\(output.pixelWidth)×\(output.pixelHeight), \(output.mediaType)).")
    }
}
