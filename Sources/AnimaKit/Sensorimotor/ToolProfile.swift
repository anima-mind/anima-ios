// ToolProfile.swift — qué tools ve cada proveedor y con qué forma. Los remotos
// (Claude / OpenAI / Gemini) reciben el registro completo. El modelo de Apple
// (Foundation Models, ventana de 4096) recibe solo lo útil en Solo teléfono, en
// forma mínima: descripción de una línea y schema sin enums (el framework
// expande cada enum a anyOf y se come la ventana): los vocabularios cerrados
// van en la descripción y, si no caben, en una pista corta del campo. Los
// nombres de parámetro son los mismos del schema completo: la ejecución no cambia.
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
    /// En local solo viaja lo que tiene forma compacta: lo demás no se manda.
    public func apply(_ specs: [ToolSpec]) -> [ToolSpec] {
        switch self {
        case .full:
            return specs
        case .onDevice:
            return specs.compactMap { spec in
                guard case .client(let name, _, _) = spec else { return nil }
                return Self.compact[name]
            }
        }
    }

    /// Lo que el modelo local deliberadamente no recibe (cámara/fotos y audio: no
    /// ve imágenes ni oye; gafas; contexto del teléfono). Documental: no viajar
    /// es el default de toda tool sin forma compacta.
    public static let excludedOnDevice: Set<String> = [
        "camera", "audio", "glasses_show", "glasses_camera", "phone_context",
    ]

    static let compact: [String: ToolSpec] = [
        "anima_reminders": tool(
            "anima_reminders",
            "Recordatorios: action list|create|complete|cancel|snooze; fire_at ISO 8601; repeat none|daily|weekdays|weekly",
            ["action": .string, "text": .string, "message": .string, "fire_at": .string,
             "repeat": .string, "goal_id": .string, "id": .string, "minutes": .integer]),
        "goals": tool(
            "goals",
            "Metas. action list|declare|set_checkin|clear_checkin|record_checkin|mark_achieved; cadence none|daily|weekdays|weekly",
            ["action": .string, "statement": .string, "goal_id": .string, "cadence": .string,
             "hour": .integer("0-23"), "minute": .integer, "weekday": .integer("1-7, 1=domingo"),
             "answer": .string("yes|partial|no|skipped")]),
        "calendar": tool(
            "calendar",
            "Agenda del iPhone (citas, agéndame). action list|search|create|delete; start/end ISO 8601",
            ["action": .string, "days_ahead": .integer, "query": .string, "title": .string,
             "start": .string, "end": .string, "event_id": .string]),
        "reminders": tool(
            "reminders",
            "App Recordatorios del iPhone, solo si la pide. action list|create|complete; due ISO 8601",
            ["action": .string, "title": .string, "due": .string, "reminder_id": .string]),
        "notes": tool(
            "notes",
            "Tus notas de texto. action create|read|list|append; name, content",
            ["action": .string, "name": .string, "content": .string]),
    ]

    /// Campo del schema mínimo: tipo y, solo si el vocabulario no cupo en la
    /// descripción de la tool, una pista corta (jamás `enum`).
    struct Field {
        var type: String
        var hint: String?

        static let string = Field(type: "string")
        static let integer = Field(type: "integer")
        static func string(_ hint: String) -> Field { Field(type: "string", hint: hint) }
        static func integer(_ hint: String) -> Field { Field(type: "integer", hint: hint) }

        var schema: JSONValue {
            var object: [String: JSONValue] = ["type": .string(type)]
            if let hint { object["description"] = .string(hint) }
            return .object(object)
        }
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Field]) -> ToolSpec {
        .client(name: name, description: description, inputSchema: .object([
            "type": .string("object"),
            "properties": .object(properties.mapValues(\.schema)),
            "required": .array([.string("action")]),
            "additionalProperties": .bool(false),
        ]))
    }
}
