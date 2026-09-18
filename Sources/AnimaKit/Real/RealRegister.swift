// RealRegister.swift — el registro determinístico del fallo (§5.6). Actor,
// escritor sobre la DatabaseQueue compartida. record() cuesta 0 LLM y siempre
// corre. Al cruzar el umbral de insistencia (N por sesión o M por día) el patrón
// se marca demanding y entra a la restructure queue; demand() la devuelve. El
// AgentLoop la consulta para rutear el turno a .restructure; el Consolidator la
// procesa a una lección y marca el patrón resuelto (se reabre si reincide).

import Foundation
import GRDB

/// Tipo de reestructuración (§5.6). En Fase 3 el SkillEngine aún no existe: los
/// fallos de riesgo (permisos, escritura) escalan al Otro, el resto revisan la
/// auto-creencia de capacidad.
public enum RestructureKind: String, Sendable, Codable, Equatable {
    case reviseSkill
    case reviseSelfBelief
    case reviseWorldModel
    case escalateToOther
}

/// Una demanda de reestructuración encolada por la insistencia de lo Real.
public struct RestructureRequest: Sendable, Equatable, Codable {
    public var patternKey: String
    public var toolName: String
    public var errorClass: String
    public var target: String?
    public var count: Int
    public var kind: RestructureKind
    public var summary: String     // el historial del patrón, para el mid-conversation system

    public init(patternKey: String, toolName: String, errorClass: String, target: String?,
                count: Int, kind: RestructureKind, summary: String) {
        self.patternKey = patternKey
        self.toolName = toolName
        self.errorClass = errorClass
        self.target = target
        self.count = count
        self.kind = kind
        self.summary = summary
    }
}

public actor RealRegister {
    private let queue: DatabaseQueue
    private let sessionThreshold: Int   // N fallos en una sesión → demanding
    private let dailyThreshold: Int     // M fallos en un día → demanding
    private let now: @Sendable () -> Date

    public init(queue: DatabaseQueue,
                sessionThreshold: Int = 3,
                dailyThreshold: Int = 5,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.queue = queue
        self.sessionThreshold = sessionThreshold
        self.dailyThreshold = dailyThreshold
        self.now = now
    }

    // MARK: - record (0 LLM, siempre)

    public func record(_ failure: Failure) {
        let key = failure.pattern.key
        let ts = failure.timestamp.timeIntervalSince1970
        let day = Self.dayString(failure.timestamp)
        try? queue.write { db in
            try db.execute(sql: """
                INSERT INTO real_failure
                    (pattern_key, tool_name, error_class, target, arg_shape, session_id, raw_error, ts, day)
                VALUES (?,?,?,?,?,?,?,?,?)
                """, arguments: [key, failure.pattern.toolName, failure.pattern.errorClass,
                                 failure.pattern.targetResource, failure.pattern.argShape,
                                 failure.sessionId, failure.rawError, ts, day])

            // upsert del patrón (reabre si estaba resuelto y reincide).
            let existing = try Row.fetchOne(db, sql: "SELECT status FROM real_pattern WHERE pattern_key=?", arguments: [key])
            if existing == nil {
                try db.execute(sql: """
                    INSERT INTO real_pattern
                        (pattern_key, tool_name, error_class, target, first_seen, last_seen, total_count, status, resolved_at)
                    VALUES (?,?,?,?,?,?,1,'active',NULL)
                    """, arguments: [key, failure.pattern.toolName, failure.pattern.errorClass,
                                     failure.pattern.targetResource, ts, ts])
            } else {
                let status: String = existing!["status"]
                let reopen = status == "resolved"
                try db.execute(sql: """
                    UPDATE real_pattern
                    SET last_seen=?, total_count = total_count + 1,
                        status = CASE WHEN ?='resolved' THEN 'active' ELSE status END,
                        resolved_at = CASE WHEN ?='resolved' THEN NULL ELSE resolved_at END
                    WHERE pattern_key=?
                    """, arguments: [ts, status, status, key])
                _ = reopen
            }

            // insistencia: N por sesión O M por día.
            let sessionCount: Int = failure.sessionId.flatMap { sid in
                try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM real_failure WHERE pattern_key=? AND session_id=?",
                                  arguments: [key, sid])
            } ?? 0
            let dayCount = (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM real_failure WHERE pattern_key=? AND day=?",
                                              arguments: [key, day])) ?? 0
            let crossed = sessionCount >= sessionThreshold || dayCount >= dailyThreshold
            let currentStatus: String = (try Row.fetchOne(db, sql: "SELECT status FROM real_pattern WHERE pattern_key=?", arguments: [key]))?["status"] ?? "active"
            let alreadyPending = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM restructure_queue WHERE pattern_key=? AND status='pending'", arguments: [key]) ?? 0) > 0

            if crossed && currentStatus != "demanding" && !alreadyPending {
                let total = (try Int.fetchOne(db, sql: "SELECT total_count FROM real_pattern WHERE pattern_key=?", arguments: [key])) ?? sessionCount
                try db.execute(sql: "UPDATE real_pattern SET status='demanding' WHERE pattern_key=?", arguments: [key])
                let request = Self.buildRequest(pattern: failure.pattern, count: max(total, sessionCount))
                let json = String(data: (try? JSONEncoder().encode(request)) ?? Data(), encoding: .utf8) ?? "{}"
                try db.execute(sql: """
                    INSERT INTO restructure_queue (pattern_key, request_json, status, created_at, resolved_at)
                    VALUES (?,?, 'pending', ?, NULL)
                    """, arguments: [key, json, ts])
            }
        }
    }

    // MARK: - insistencia / demanda

    /// Cuántas veces ha insistido el patrón (total acumulado).
    public func insistence(_ key: PatternKey) -> Int {
        (try? queue.read { db in
            try Int.fetchOne(db, sql: "SELECT total_count FROM real_pattern WHERE pattern_key=?", arguments: [key.key])
        }).flatMap { $0 } ?? 0
    }

    /// Las reestructuraciones pendientes (el AgentLoop y el Consolidator las leen).
    public func demand() -> [RestructureRequest] {
        (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT request_json FROM restructure_queue WHERE status='pending' ORDER BY created_at ASC")
                .compactMap { row -> RestructureRequest? in
                    guard let json: String = row["request_json"], let data = json.data(using: .utf8) else { return nil }
                    return try? JSONDecoder().decode(RestructureRequest.self, from: data)
                }
        }) ?? []
    }

    /// El Consolidator marca resuelto tras generar la lección (§5.4/§5.6). El
    /// patrón se reabre solo si reincide (nuevos fallos tras resolved_at).
    public func resolve(patternKey: String) {
        let ts = now().timeIntervalSince1970
        try? queue.write { db in
            try db.execute(sql: "UPDATE restructure_queue SET status='resolved', resolved_at=? WHERE pattern_key=? AND status='pending'",
                           arguments: [ts, patternKey])
            try db.execute(sql: "UPDATE real_pattern SET status='resolved', resolved_at=? WHERE pattern_key=?",
                           arguments: [ts, patternKey])
        }
    }

    /// Diagnóstico/tests: estado de un patrón.
    public func status(_ key: PatternKey) -> String? {
        (try? queue.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM real_pattern WHERE pattern_key=?", arguments: [key.key])
        }).flatMap { $0 }
    }

    // MARK: - Helpers

    static func buildRequest(pattern: PatternKey, count: Int) -> RestructureRequest {
        let risky = ["permission_denied", "os_error", "fatal"].contains(pattern.errorClass)
        let kind: RestructureKind = risky ? .escalateToOther : .reviseSelfBelief
        let onTarget = pattern.targetResource.map { " sobre '\($0)'" } ?? ""
        let summary = "La estrategia con la tool '\(pattern.toolName)' ha fallado \(count) veces con el error '\(pattern.errorClass)'\(onTarget). "
            + "Esta aproximación no está funcionando: cambia de estrategia en lugar de repetir la misma llamada."
        return RestructureRequest(patternKey: pattern.key, toolName: pattern.toolName,
                                  errorClass: pattern.errorClass, target: pattern.targetResource,
                                  count: count, kind: kind, summary: summary)
    }

    static func dayString(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
