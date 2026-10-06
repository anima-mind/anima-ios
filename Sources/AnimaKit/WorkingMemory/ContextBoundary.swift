// ContextBoundary.swift — dónde EMPIEZA el contexto de una sesión (batch 5b
// #4/#5). El transcript canónico nunca se borra (la noche lo sigue viendo); una
// frontera dice desde qué turno arma el modelo su ventana:
//   · trim       — recorte duro determinista para caber en el modelo activo;
//   · compaction — la conversación anterior quedó resumida (`summary`) y el
//                  resumen abre la ventana.

import Foundation
import GRDB

public struct ContextBoundary: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case trim, compaction
    }

    public var kind: Kind
    /// Primer seq del transcript que sigue en el contexto.
    public var fromSeq: Int
    public var summary: String?
    /// Nombre legible del modelo para el que se recortó.
    public var model: String?
    public var createdAt: Date

    /// Abre la ventana tras una compactación (va como turno del dueño: los
    /// providers exigen empezar por user; es contexto, no una orden).
    public static let summaryHeader = "[RESUMEN DE LA CONVERSACIÓN ANTERIOR — lo escribiste tú al compactar]"

    /// El separador del chat.
    public var dividerText: String {
        switch kind {
        case .trim: return "Recorté la conversación para caber en \(model ?? "el modelo")"
        case .compaction: return "Conversación compactada"
        }
    }
}

public enum ContextSchema {
    public static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("v15-context-boundary") { db in
            try db.execute(sql: """
                CREATE TABLE context_boundary (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL REFERENCES session(id),
                    from_seq INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    summary TEXT NULL,
                    model TEXT NULL,
                    created_at REAL NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_context_boundary_session ON context_boundary(session_id, id);")
        }
    }
}

extension SymbolicStore {
    /// Último seq de la sesión (0 si no hay eventos).
    public func lastSeq(sessionId: SessionID) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq),0) FROM turn_event WHERE session_id=?",
                             arguments: [sessionId]) ?? 0
        }
    }

    public func addBoundary(sessionId: SessionID, kind: ContextBoundary.Kind, fromSeq: Int,
                            summary: String? = nil, model: String? = nil, at date: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO context_boundary (session_id, from_seq, kind, summary, model, created_at)
                VALUES (?,?,?,?,?,?)
                """, arguments: [sessionId, fromSeq, kind.rawValue, summary, model, date.timeIntervalSince1970])
        }
    }

    public func boundaries(sessionId: SessionID) throws -> [ContextBoundary] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM context_boundary WHERE session_id=? ORDER BY id ASC",
                             arguments: [sessionId]).compactMap { row in
                guard let kind = ContextBoundary.Kind(rawValue: row["kind"]) else { return nil }
                return ContextBoundary(kind: kind, fromSeq: row["from_seq"], summary: row["summary"],
                                       model: row["model"],
                                       createdAt: Date(timeIntervalSince1970: row["created_at"]))
            }
        }
    }

    /// La frontera vigente: la última registrada.
    public func currentBoundary(sessionId: SessionID) throws -> ContextBoundary? {
        try boundaries(sessionId: sessionId).last
    }

    /// "Nueva conversación": cierra limpio la sesión actual y abre otra. La
    /// memoria, las metas y los recordatorios viven en otras tablas: intactos.
    public func beginNewConversation(after current: SessionID?) throws -> SessionID {
        if let current { try markCleanShutdown(current) }
        return try startSession()
    }
}
