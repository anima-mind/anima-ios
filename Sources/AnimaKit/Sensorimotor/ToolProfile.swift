// ToolProfile.swift — qué tools ve cada proveedor y con qué forma. Los remotos
// (Claude / OpenAI / Gemini) reciben el registro completo. El modelo de Apple
// (Foundation Models, ventana de 4096) recibe solo lo útil en Solo teléfono, en
// forma mínima: descripción de una línea y schema sin descripciones por campo
// ni enums (el framework expande cada enum a anyOf y se come la ventana; los
// valores válidos van en la descripción). Los nombres de parámetro son los
// mismos del schema completo: la ejecución no cambia.
//
// Medido con `SystemLanguageModel.tokenCount(for: [Tool])`: registro completo
// 3797 tokens; perfil local ver `ToolProfileTests`.

import Foundation

public enum ToolProfile: Sendable, Equatable {
    case full
    case onDevice

    public static func `for`(model: String) -> ToolProfile {
        model == OnDeviceProvider.modelName ? .onDevice : .full
    }

    /// Aplica el perfil. Idempotente: el loop y el provider pueden aplicarlo ambos.
    /// En local, una tool fuera de `compact` y de `excludedOnDevice` pasa tal cual
    /// (un test exige que cada tool del registro esté en una de las dos).
    public func apply(_ specs: [ToolSpec]) -> [ToolSpec] {
        switch self {
        case .full:
            return specs
        case .onDevice:
            return specs.compactMap { spec in
                guard case .client(let name, _, _) = spec, !Self.excludedOnDevice.contains(name) else { return nil }
                return Self.compact[name] ?? spec
            }
        }
    }

    /// Tools que el modelo local nunca recibe (cámara/fotos y audio: no ve
    /// imágenes ni oye; gafas; contexto del teléfono: el reloj ya va en el contexto).
    public static let excludedOnDevice: Set<String> = [
        "camera", "audio", "glasses_show", "glasses_camera", "phone_context",
    ]

    static let compact: [String: ToolSpec] = [
        "anima_reminders": tool(
            "anima_reminders",
            "Tus recordatorios (recuérdame…). action list|create|complete|cancel|snooze; create: text, message, fire_at ISO",
            ["action": "string", "text": "string", "message": "string", "fire_at": "string",
             "repeat": "string", "goal_id": "string", "id": "string", "minutes": "integer"]),
        "goals": tool(
            "goals",
            "Metas del dueño. action list|declare|set_checkin|clear_checkin|record_checkin|mark_achieved",
            ["action": "string", "statement": "string", "goal_id": "string", "cadence": "string",
             "hour": "integer", "minute": "integer", "weekday": "integer", "answer": "string"]),
        "calendar": tool(
            "calendar",
            "Agenda del iPhone (citas, agéndame). action list|search|create|delete; start/end ISO 8601",
            ["action": "string", "days_ahead": "integer", "query": "string", "title": "string",
             "start": "string", "end": "string", "event_id": "string"]),
        "reminders": tool(
            "reminders",
            "App Recordatorios del iPhone, solo si la pide. action list|create|complete; due ISO 8601",
            ["action": "string", "title": "string", "due": "string", "reminder_id": "string"]),
        "notes": tool(
            "notes",
            "Tus notas de texto. action create|read|list|append; name, content",
            ["action": "string", "name": "string", "content": "string"]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: String]) -> ToolSpec {
        .client(name: name, description: description, inputSchema: .object([
            "type": .string("object"),
            "properties": .object(properties.mapValues { .object(["type": .string($0)]) }),
            "required": .array([.string("action")]),
            "additionalProperties": .bool(false),
        ]))
    }
}
