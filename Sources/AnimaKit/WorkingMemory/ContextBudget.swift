// ContextBudget.swift — cuánto cuesta en tokens lo fijo de cada request (system
// base + herramientas), medido sobre lo que cada proveedor manda de verdad:
//
// - remote (Claude / OpenAI-compat): cada tool viaja como JSON
//   {name, description, input_schema}; las server-side (web_search) suman su
//   definición. JSON ≈ 4.2 chars/token, prosa ≈ 3.6.
// - onDevice (Foundation Models): solo las client-side, como `Tool` con su
//   `GenerationSchema` (traducción del JSON Schema, ver OnDeviceProvider). El
//   framework las mete en la ventana de 4096: calibrado con
//   `SystemLanguageModel.tokenCount(for: [Tool])` sobre las 10 tools reales
//   (3797 tokens para 9478 chars de nombre + descripción + schema ⇒ 2.5
//   chars/token; el español y los enums expandidos tokenizan caro).

import Foundation

public enum ContextBudget: Sendable, Equatable {
    case remote
    case onDevice

    public static func `for`(model: String) -> ContextBudget {
        model == OnDeviceProvider.modelName ? .onDevice : .remote
    }

    static let proseCharsPerToken = 3.6
    static let remoteToolCharsPerToken = 4.2
    static let onDeviceToolCharsPerToken = 2.5

    public func fixedTokens(systemBase: String, tools: [ToolSpec]) -> Int {
        Int(Double(systemBase.count) / Self.proseCharsPerToken) + toolTokens(tools)
    }

    public func toolTokens(_ tools: [ToolSpec]) -> Int {
        switch self {
        case .remote:
            return Int(Double(ContextGauge.toolChars(tools)) / Self.remoteToolCharsPerToken)
        case .onDevice:
            let local = tools.filter { if case .client = $0 { return true } else { return false } }
            return Int(Double(ContextGauge.toolChars(local)) / Self.onDeviceToolCharsPerToken)
        }
    }
}
