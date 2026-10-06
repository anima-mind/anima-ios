// ContextBudget.swift — cuánto cuesta en tokens lo fijo de cada request (system
// base + herramientas), medido sobre lo que cada proveedor manda de verdad:
//
// - remote (Claude / OpenAI-compat): cada tool viaja como JSON
//   {name, description, input_schema}; las server-side (web_search) suman su
//   definición. JSON ≈ 4.2 chars/token, prosa ≈ 3.6.
// - onDevice (Foundation Models): las tools del perfil `ToolProfile.onDevice`,
//   como `Tool` con su `GenerationSchema`. Calibrado con
//   `SystemLanguageModel.tokenCount(for: [Tool])` (≈ 2.5 chars/token: el
//   español y los schemas tokenizan caro).

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
            let local = ToolProfile.onDevice.apply(tools)
            return Int(Double(ContextGauge.toolChars(local)) / Self.onDeviceToolCharsPerToken)
        }
    }
}
