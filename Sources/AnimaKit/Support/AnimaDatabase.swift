// AnimaDatabase.swift — un solo motor GRDB para todo el estado local
// (plan doc 04 §2: "un solo motor para transcript, brain, failures, goals").
// Fase 0 crea las tablas del SymbolicStore (§5.2) y de Telemetry (§3).
// Migraciones versionadas: cada release agrega una migración, nunca edita una vieja.

import Foundation
import GRDB

public enum AnimaDatabase {

    public static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1-symbolic-telemetry") { db in
            // Transcript canónico (§5.2). Timestamps como epoch seconds (REAL) —
            // el recovery compara Δt en Swift, no en SQL.
            try db.execute(sql: """
                CREATE TABLE session (
                    id TEXT PRIMARY KEY,
                    started_at REAL NOT NULL,
                    clean_shutdown INTEGER NOT NULL DEFAULT 0,
                    restart_count INTEGER NOT NULL DEFAULT 0,
                    last_event_at REAL
                );
                """)
            try db.execute(sql: """
                CREATE TABLE turn_event (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL REFERENCES session(id),
                    seq INTEGER NOT NULL,
                    role TEXT NOT NULL,
                    content_json TEXT NOT NULL,
                    usage_json TEXT,
                    created_at REAL NOT NULL,
                    UNIQUE(session_id, seq)
                );
                """)
            // Telemetría de costos: usage por turno + tool calls + retries (§7).
            try db.execute(sql: """
                CREATE TABLE turn_telemetry (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    turn_class TEXT NOT NULL,
                    model TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    cache_read_tokens INTEGER NOT NULL DEFAULT 0,
                    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
                    tool_calls INTEGER NOT NULL DEFAULT 0,
                    retries INTEGER NOT NULL DEFAULT 0,
                    ts REAL NOT NULL
                );
                """)
        }

        // Fase 2 (§5.3, §5.4): Brain bi-temporal + FTS5 + embeddings +
        // Consolidator (inbox, ciclos reanudables, cycle_log).
        BrainSchema.register(&m)

        // Fase 3 (§5.5, §5.6): SelfModel (identidad + plasticidad + approvals) y
        // RealRegister (fallos por PatternKey + restructure queue).
        SelfModelSchema.register(&m)
        RealSchema.register(&m)

        return m
    }

    /// Abre (o crea) la base en `path` y aplica migraciones.
    public static func makeQueue(path: String) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path)
        try migrator().migrate(queue)
        return queue
    }

    /// Base efímera en un archivo temporal único — para tests y previews.
    public static func temporary() throws -> DatabaseQueue {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        return try makeQueue(path: url.path)
    }
}
