// ToolProfile.swift — qué tools ve cada proveedor y con qué forma. Los remotos
// (Claude / OpenAI / Gemini) reciben el registro completo. El modelo de Apple
// (Foundation Models, ~3B, ventana de 4096) recibe el set del `LocalToolAdapter`:
// una intención por tool, parámetros obligatorios y un ejemplo literal; el
// adapter traduce cada llamada a la tool real antes del Sensorimotor.
//
// Medido con `SystemLanguageModel.tokenCount(for: [Tool])`: registro completo
// 3797 tokens; set local ver `ToolProfileTests`.

import Foundation

public enum ToolProfile: Sendable, Equatable {
    case full
    case onDevice

    public static func `for`(model: String) -> ToolProfile {
        OnDeviceProvider.isOnDevice(model: model) ? .onDevice : .full
    }

    /// Aplica el perfil. Idempotente: el loop y el provider pueden aplicarlo ambos.
    /// En local solo viajan las tools del adapter cuya tool real está registrada.
    public func apply(_ specs: [ToolSpec]) -> [ToolSpec] {
        switch self {
        case .full: return specs
        case .onDevice: return LocalToolAdapter.specs(for: specs)
        }
    }

    /// Lo que el modelo local deliberadamente no recibe: cámara/fotos y audio (no
    /// ve imágenes ni oye), gafas, contexto del teléfono y la app Recordatorios del
    /// iPhone (con un 3B la confundía con sus recordatorios; la agenda es
    /// `add_calendar_event`). Documental: no viajar es el default.
    public static let excludedOnDevice: Set<String> = [
        "camera", "audio", "glasses_show", "glasses_camera", "phone_context", "reminders",
    ]
}
