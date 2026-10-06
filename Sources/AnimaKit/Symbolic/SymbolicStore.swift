// SymbolicStore.swift — transcript canónico en GRDB (§5.2). Sesiones +
// mensajes append-only, tool_use/tool_result incluidos como content blocks.
// El transcript es la fuente de verdad: la UI y la WorkingMemory se derivan de él.

import Foundation
import GRDB

public typealias SessionID = String

public struct SessionState: Sendable, Equatable {
    public var id: SessionID
    public var startedAt: Date
    public var cleanShutdown: Bool
    public var restartCount: Int
    public var lastEventAt: Date?
}

/// GRDB es thread-safe; no requiere actor. `DatabaseQueue` es Sendable.
public final class SymbolicStore: Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// La base compartida (§2: un solo motor). El Brain y el Consolidator se
    /// cablean sobre la misma DatabaseQueue (escritor único = el gate gratis).
    public var database: DatabaseQueue { queue }

    // MARK: - Sesiones

    @discardableResult
    public func startSession(id: SessionID = UUID().uuidString) throws -> SessionID {
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO session (id, started_at, clean_shutdown, restart_count, last_event_at) VALUES (?,?,0,0,NULL)",
                arguments: [id, now])
        }
        return id
    }

    public func session(_ id: SessionID) throws -> SessionState? {
        try queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM session WHERE id=?", arguments: [id]) else {
                return nil
            }
            return Self.state(from: row)
        }
    }

    /// Marca la sesión como cerrada limpiamente (scenePhase .background).
    public func markCleanShutdown(_ id: SessionID) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE session SET clean_shutdown=1 WHERE id=?", arguments: [id])
        }
    }

    /// La sesión reanudada vuelve a estar viva (el próximo background la cierra limpio).
    public func markActive(_ id: SessionID) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE session SET clean_shutdown=0 WHERE id=?", arguments: [id])
        }
    }

    public func incrementRestartCount(_ id: SessionID) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE session SET restart_count = restart_count + 1 WHERE id=?", arguments: [id])
        }
    }

    // MARK: - Eventos (append-only)

    /// Agrega un mensaje al transcript. `usage` se guarda para telemetría/costos;
    /// `surface` marca por dónde llegó (teléfono / gafas) — mismo transcript.
    public func append(sessionId: SessionID, message: Message, usage: Usage? = nil,
                       surface: SurfaceID? = nil, proactive: ProactiveTag? = nil) throws {
        let contentJSON = try Self.encodeBlocks(message.content)
        let usageJSON = try usage.map { try Self.encodeUsage($0) }
        let proactiveJSON = try proactive.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            let seq = (try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(seq),0) FROM turn_event WHERE session_id=?",
                arguments: [sessionId]) ?? 0) + 1
            try db.execute(
                sql: """
                    INSERT INTO turn_event (session_id, seq, role, content_json, usage_json, created_at, surface,
                                            proactive_json)
                    VALUES (?,?,?,?,?,?,?,?)
                    """,
                arguments: [sessionId, seq, message.role.rawValue, contentJSON, usageJSON, now, surface?.rawValue,
                            proactiveJSON])
            try db.execute(sql: "UPDATE session SET last_event_at=? WHERE id=?", arguments: [now, sessionId])
        }
    }

    /// Reconstruye la ventana de historial (Message[]) para el ensamblado del turno.
    /// Recorta los mensajes más viejos si excede el presupuesto de tokens (heurística chars/3.6).
    public func window(sessionId: SessionID, budgetTokens: Int = Int.max) throws -> [Message] {
        let messages: [Message] = try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT role, content_json FROM turn_event WHERE session_id=? ORDER BY seq ASC",
                arguments: [sessionId])
            return try rows.compactMap { row -> Message? in
                guard let roleRaw: String = row["role"],
                      let role = Message.Role(rawValue: roleRaw),
                      let json: String = row["content_json"] else { return nil }
                let blocks = try Self.decodeBlocks(json)
                return Message(role: role, content: blocks)
            }
        }
        return Self.trim(messages, budgetTokens: budgetTokens)
    }

    /// La superficie de cada evento del transcript, en orden (nil = sin marca).
    public func surfaces(sessionId: SessionID) throws -> [SurfaceID?] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT surface FROM turn_event WHERE session_id=? ORDER BY seq ASC",
                             arguments: [sessionId])
                .map { row in (row["surface"] as String?).flatMap(SurfaceID.init(rawValue:)) }
        }
    }

    /// Los turnos VISIBLES del chat (campo #10): lo que el dueño dijo y lo que
    /// la mente respondió, con sus marcas (voz, foto, superficie). Los
    /// tool_use/tool_result crudos y el razonamiento no se pintan.
    public func visibleTurns(sessionId: SessionID) throws -> [VisibleTurn] {
        let rows: [(String, String, String?, String?, Double?)] = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT role, content_json, surface, proactive_json, created_at FROM turn_event
                WHERE session_id=? ORDER BY seq ASC
                """, arguments: [sessionId])
                .compactMap { row in
                    guard let role: String = row["role"], let json: String = row["content_json"] else { return nil }
                    return (role, json, row["surface"], row["proactive_json"], row["created_at"])
                }
        }
        return try rows.compactMap { role, json, surfaceRaw, proactiveRaw, createdAt in
            guard let role = Message.Role(rawValue: role), role == .user || role == .assistant else { return nil }
            var turn = VisibleTurn(role: role, blocks: try Self.decodeBlocks(json),
                                   surface: surfaceRaw.flatMap(SurfaceID.init(rawValue:)))
            if let raw = proactiveRaw, let tag = try? JSONDecoder().decode(ProactiveTag.self, from: Data(raw.utf8)) {
                turn?.proactive = tag
            }
            turn?.createdAt = createdAt.map(Date.init(timeIntervalSince1970:))
            return turn
        }
    }

    // MARK: - Helpers

    static func trim(_ messages: [Message], budgetTokens: Int) -> [Message] {
        guard budgetTokens != Int.max else { return messages }
        var kept: [Message] = []
        var chars = 0
        // Mantiene los más recientes: recorre de atrás hacia adelante.
        for message in messages.reversed() {
            let size = message.content.reduce(0) { $0 + Self.approxChars($1) }
            if (chars + size) / 4 > budgetTokens && !kept.isEmpty { break }
            kept.append(message)
            chars += size
        }
        return kept.reversed()
    }

    static func approxChars(_ block: ContentBlock) -> Int {
        switch block {
        case .text(let t), .thinking(let t): return t.count
        case .toolResult(_, let c, _): return c.count
        case .toolUse(_, let n, _): return n.count + 32
        case .image: return 1600 * 4  // ~1600 tokens por imagen
        }
    }

    static func state(from row: Row) -> SessionState {
        SessionState(
            id: row["id"],
            startedAt: Date(timeIntervalSince1970: row["started_at"]),
            cleanShutdown: (row["clean_shutdown"] as Int) == 1,
            restartCount: row["restart_count"],
            lastEventAt: (row["last_event_at"] as Double?).map { Date(timeIntervalSince1970: $0) })
    }

    static func encodeBlocks(_ blocks: [ContentBlock]) throws -> String {
        String(data: try JSONEncoder().encode(blocks), encoding: .utf8) ?? "[]"
    }
    static func decodeBlocks(_ json: String) throws -> [ContentBlock] {
        guard let data = json.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([ContentBlock].self, from: data)
    }
    static func encodeUsage(_ usage: Usage) throws -> String {
        let obj: [String: JSONValue] = [
            "input_tokens": .int(usage.inputTokens),
            "output_tokens": .int(usage.outputTokens),
            "cache_read_input_tokens": .int(usage.cacheReadInputTokens ?? 0),
            "cache_creation_input_tokens": .int(usage.cacheCreationInputTokens ?? 0),
        ]
        return String(data: try JSONEncoder().encode(JSONValue.object(obj)), encoding: .utf8) ?? "{}"
    }
}

/// Un turno del transcript tal como lo pinta el chat del teléfono.
public struct VisibleTurn: Sendable, Equatable {
    public var role: Message.Role
    public var text: String
    public var isVoice: Bool
    /// Bytes base64 de la primera imagen del turno (thumb de la burbuja).
    public var imageBase64: String?
    public var surface: SurfaceID?
    /// Turno proactivo (recordatorio entregado, check-in): se pinta como card.
    public var proactive: ProactiveTag?
    /// Cuándo se escribió (hora y separador de día del chat).
    public var createdAt: Date?

    public init(role: Message.Role, text: String, isVoice: Bool = false, imageBase64: String? = nil,
                surface: SurfaceID? = nil, proactive: ProactiveTag? = nil, createdAt: Date? = nil) {
        self.role = role
        self.text = text
        self.isVoice = isVoice
        self.imageBase64 = imageBase64
        self.surface = surface
        self.proactive = proactive
        self.createdAt = createdAt
    }

    /// nil si el evento no tiene nada que pintar (tool_result, tool_use puro).
    init?(role: Message.Role, blocks: [ContentBlock], surface: SurfaceID?) {
        var texts: [String] = []
        var voice = false
        var image: String?
        for block in blocks {
            switch block {
            case .text(let t):
                if role == .user, t == HUDPhoto.prompt {
                    texts.append(HUDPhoto.question)   // foto del botón de las gafas
                } else if role == .user, t.hasPrefix(AudioTool.transcriptPrefix) {
                    voice = true
                    texts.append(String(t.dropFirst(AudioTool.transcriptPrefix.count)).trimmingCharacters(in: .whitespaces))
                } else {
                    texts.append(t)
                }
            case .image(_, let base64):
                if image == nil { image = base64 }
            default:
                break   // thinking, tool_use, tool_result: no se pintan
            }
        }
        let text = texts.joined(separator: role == .assistant ? "" : "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil else { return nil }
        self.init(role: role, text: text, isVoice: voice, imageBase64: image, surface: surface)
    }
}
