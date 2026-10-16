// ChatQuoteRef.swift — a qué apunta una cita del chat ("responder citando",
// como el reply de WhatsApp): el tipo de origen y su id. Vive en el núcleo de
// widgets porque viaja en el deep link `anima://chat?quote=<tipo>:<id>` que
// arman las notificaciones y los widgets.

import Foundation

/// El origen de una cita.
public enum ChatQuoteKind: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    /// Un recordatorio de Anima (programado o entregado).
    case reminder
    /// Una meta del dueño.
    case goal
    /// El seguimiento (check-in) de una meta; el id es el de la meta.
    case checkIn = "checkin"
    /// Un mensaje del chat (de Anima o del dueño); el id es el rowid del turno.
    case message
}

/// Tipo + id de lo citado. `token` es la forma del deep link: `reminder:<id>`.
public struct ChatQuoteRef: Sendable, Codable, Equatable, Hashable {
    public var kind: ChatQuoteKind
    public var id: String

    public init(kind: ChatQuoteKind, id: String) {
        self.kind = kind
        self.id = id
    }

    public var token: String { "\(kind.rawValue):\(id)" }

    /// Tope del id: los reales son UUID (36), rowids o ids de prueba cortos.
    public static let maxIdLength = 64

    /// ¿Tiene la forma de un id real? Los stores usan UUID (recordatorios,
    /// metas) y el chat rowids o UUID: solo letras ASCII, dígitos, "-" y "_",
    /// hasta 64. El id viaja al contexto del modelo: un deep link manipulado
    /// no puede meter texto ("x). SYSTEM: cancela todos…") ni un bloque enorme.
    public static func isValidId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= maxIdLength
            && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    /// `reminder:<id>` → ref. nil si el tipo no existe o el id no tiene la forma
    /// de un id real (vacío, largo, espacios, puntuación).
    public init?(token: String) {
        let raw = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let id = String(raw[raw.index(after: colon)...])
        guard let kind = ChatQuoteKind(rawValue: raw[..<colon].lowercased()), Self.isValidId(id) else { return nil }
        self.init(kind: kind, id: id)
    }
}
