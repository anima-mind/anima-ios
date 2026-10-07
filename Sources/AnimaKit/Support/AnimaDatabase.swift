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

        // Fase 4 (§5.8, §5.7): OtherModel + log de Intentions (deseo) y la práctica
        // del SkillEngine.
        DesireSchema.register(&m)
        SkillSchema.register(&m)

        // Track G (doc 05 §3.2): la conversación es UNA; cada evento del
        // transcript lleva la superficie por la que llegó (NULL = histórico/teléfono).
        m.registerMigration("v9-turn-surface") { db in
            try db.execute(sql: "ALTER TABLE turn_event ADD COLUMN surface TEXT")
        }

        // DAT 1.0: "Hey Meta, start Anima" — una fila por fase de cada invocación.
        m.registerMigration("v10-voice-invocation") { db in
            try db.execute(sql: """
                CREATE TABLE voice_invocation_telemetry (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    phase TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    outcome TEXT,
                    delivered INTEGER,
                    detail TEXT,
                    latency_ms REAL,
                    ts REAL NOT NULL
                )
                """)
        }

        // DAT 1.0: eventos del cuerpo-gafas fuera del turno (don_wake, …).
        m.registerMigration("v11-glasses-events") { db in
            try db.execute(sql: """
                CREATE TABLE glasses_event_telemetry (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    event TEXT NOT NULL,
                    outcome TEXT NOT NULL,
                    detail TEXT,
                    ts REAL NOT NULL
                )
                """)
        }

        // Capa proactiva: recordatorios de Anima, check-ins por meta, origen de Intentions.
        ProactiveSchema.register(&m)
        // Fronteras de contexto (recorte duro / compactación) por sesión.
        ContextSchema.register(&m)

        return m
    }

    /// Abre (o crea) la base en `path` y aplica migraciones. Observa la
    /// suspensión de GRDB (DatabaseSuspension): la base vive en el App Group.
    public static func makeQueue(path: String) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path, configuration: configuration())
        try migrator().migrate(queue)
        return queue
    }

    static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.observesSuspensionNotifications = true
        return configuration
    }

    /// Base en memoria (jamás toca disco): sesiones efímeras de propósito como el
    /// taller de skills — su transcript muere con la pantalla.
    public static func inMemory() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
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
