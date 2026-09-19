// AudioTool.swift — contrato de la tool `audio` (§5.7). La grabación + el
// SFSpeechRecognizer on-device (es-CO) viven en UI/ (#if os(iOS)); aquí el
// contrato + el formateo puro. El audio crudo JAMÁS viaja a la API: solo el
// transcript, prefijado. Regla de captura (§8): .efferent → siempre `ask`.

import Foundation

public struct AudioTool: SensorimotorTool {
    /// La UI de iOS inyecta grabación + transcripción on-device; devuelve el texto.
    public typealias Transcribe = @Sendable (_ maxSeconds: Int) async -> String?
    private let transcribe: Transcribe?

    public init(transcribe: Transcribe? = nil) {
        self.transcribe = transcribe
    }

    public static let transcriptPrefix = "[transcrito de audio]"

    /// El transcript entra como TEXTO del turno, prefijado (§ multimodal).
    public static func transcriptText(_ transcript: String) -> String {
        "\(transcriptPrefix) \(transcript)"
    }

    public static func transcriptBlock(_ transcript: String) -> ContentBlock {
        .text(transcriptText(transcript))
    }

    public var spec: ToolSpec {
        .client(
            name: "audio",
            description: """
                Graba una nota de voz del dueño y la transcribe en el dispositivo \
                (es-CO). Requiere su confirmación. El audio crudo no sale del \
                teléfono: solo llega el texto transcrito. Úsala cuando el dueño \
                prefiera hablar en vez de escribir.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "max_seconds": .object([
                        "type": .string("integer"),
                        "description": .string("Duración máxima de la grabación en segundos (default 60)."),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]))
    }

    public func kind(for input: JSONValue) -> ToolKind { .efferent }
    public func operation(for input: JSONValue) -> String { "record" }
    public func confirmationSummary(for input: JSONValue) -> String {
        let seconds = maxSeconds(input)
        return "Grabar y transcribir audio (hasta \(seconds)s, on-device)"
    }

    public func execute(_ input: JSONValue) async -> ToolResult {
        guard let transcribe else {
            return ToolResult(content: "La grabación de audio la inicia el dueño desde la app.")
        }
        guard let transcript = await transcribe(maxSeconds(input)), !transcript.isEmpty else {
            return ToolResult(content: "No se obtuvo transcripción.", isError: true)
        }
        return ToolResult(content: Self.transcriptText(transcript))
    }

    private func maxSeconds(_ input: JSONValue) -> Int {
        if case .int(let n) = input["max_seconds"] { return max(1, min(300, n)) }
        return 60
    }
}
