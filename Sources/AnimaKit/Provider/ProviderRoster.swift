// ProviderRoster.swift — Ajustes → Modelo como UNA lista de providers (campo #13).
// Antes había dos selectores paralelos (chips del activo + segmented del editor
// de key) y los estados se cruzaban. Ahora cada fila es un provider: radio de
// ACTIVO (solo si tiene key, o si es el local disponible) + estado inline +
// acción. Puro: el view model solo lo pinta.

import Foundation

public struct ProviderRow: Sendable, Equatable, Identifiable {
    public let provider: ModelProvider
    public var hasKey: Bool
    /// Claude: api key u OAuth (detectado del token). nil en compat y local.
    public var authMode: AuthMode?
    public var isActive: Bool
    /// El radio se puede elegir (tiene key / el local está disponible).
    public var selectable: Bool
    public var status: String
    /// Local no disponible: el porqué.
    public var detail: String?

    public var id: String { provider.rawValue }
    /// Punto accent (● listo) vs border (○ falta algo).
    public var isReady: Bool { provider.isRemote ? hasKey : selectable }

    /// "Agregar key" / "Cambiar key"; nil en el local.
    public var actionTitle: String? {
        guard provider.isRemote else { return nil }
        return hasKey ? "Cambiar key" : "Agregar key"
    }
}

public enum ProviderRoster {
    public static let localName = "Modelo local"

    /// Las filas: los remotos y, al final, el modelo local.
    public static func rows(tokens: [ModelProvider: String], activeRemote: ModelProvider, mode: OperatingMode,
                            local: OnDeviceAvailability) -> [ProviderRow] {
        var rows = ModelProvider.remoteCases.map { provider -> ProviderRow in
            let token = tokens[provider]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasKey = !token.isEmpty
            let auth = provider == .anthropic && hasKey ? AuthMode.detect(fromToken: token) : nil
            return ProviderRow(provider: provider, hasKey: hasKey, authMode: auth,
                               isActive: mode != .onDeviceOnly && provider == activeRemote,
                               selectable: hasKey, status: status(hasKey: hasKey, auth: auth))
        }
        rows.append(ProviderRow(provider: .onDevice, hasKey: false, authMode: nil,
                                isActive: mode == .onDeviceOnly, selectable: local.isAvailable,
                                status: (local.isAvailable ? "● " : "○ ") + local.label, detail: local.reason))
        return rows
    }

    static func status(hasKey: Bool, auth: AuthMode?) -> String {
        guard hasKey else { return "○ sin key" }
        switch auth {
        case .oauth?: return "● key guardada · OAuth"
        case .apiKey?: return "● key guardada · API key"
        case nil: return "● key guardada"
        }
    }

    /// Tras borrar la key del ACTIVO: el siguiente remoto con key, si no el
    /// local disponible; nil si no queda ninguno.
    public static func fallback(afterDeleting provider: ModelProvider, saved: Set<ModelProvider>,
                                local: OnDeviceAvailability) -> ModelProvider? {
        if let next = ModelProvider.remoteCases.first(where: { $0 != provider && saved.contains($0) }) { return next }
        return local.isAvailable ? .onDevice : nil
    }
}
