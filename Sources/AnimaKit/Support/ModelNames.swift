// ModelNames.swift — ids de modelo → nombre para humanos en Ajustes ("Modelo
// local (Apple)", "Claude Opus 4.8"), con fallback al id; y la clase de turno
// en español. Normaliza el id (trim + minúsculas) para agrupar costos.

import Foundation

public enum ModelNames {
    public static func normalized(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).lowercased()
    }

    /// "claude-opus-4-8" → "Claude Opus 4.8"; "gpt-5-mini" → "GPT-5 mini";
    /// "gemini-3.1-pro-preview" → "Gemini 3.1 Pro (preview)"; desconocido → el id.
    public static func friendly(_ raw: String) -> String {
        let model = normalized(raw)
        if OnDeviceProvider.isOnDevice(model: model) { return "Modelo local (Apple)" }
        let parts = model.split(separator: "-").map(String.init)
        guard let family = parts.first else { return raw }
        switch family {
        case "claude":
            guard parts.count >= 3 else { return raw }
            let tier = parts[1].capitalized
            let version = parts.dropFirst(2).prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }
            guard !version.isEmpty else { return "Claude \(tier)" }
            return "Claude \(tier) \(version.joined(separator: "."))"
        case "gpt":
            guard parts.count >= 2 else { return raw }
            let rest = parts.dropFirst(2).joined(separator: " ")
            return "GPT-\(parts[1])" + (rest.isEmpty ? "" : " \(rest)")
        case "gemini":
            guard parts.count >= 2 else { return raw }
            var words = parts.dropFirst(2).map { $0 == "preview" ? "(preview)" : $0.capitalized }
            words.insert(parts[1], at: 0)
            return "Gemini " + words.joined(separator: " ")
        default:
            return raw
        }
    }

    public static func turnClassLabel(_ raw: String) -> String {
        switch TurnClass(rawValue: raw) {
        case .interactive, .interactiveHard: return "Conversación"
        case .restructure: return "Replanteo"
        case .consolidation, .reconsolidation, .distill: return "Sueño"
        case .desirePulse: return "Pulso"
        case nil: return raw
        }
    }
}
