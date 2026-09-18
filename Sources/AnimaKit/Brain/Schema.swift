// Schema.swift — migración GRDB v2 del Brain (§5.3) y del Consolidator (§5.4).
// La memoria es bi-temporal: created_at (transaction time), event_at (valid time)
// e invalidated_at + invalidation_reason. NUNCA se hace DELETE de una memoria:
// invalidar es marcar, con razón visible. FTS5 (BM25) se sincroniza por triggers
// sobre external-content; los embeddings viven aparte para poder re-embeber si
// cambia el modelo/OS (embedder_rev). El ciclo de consolidación es reanudable:
// su estado (etapa, destilados, decisiones) se persiste en GRDB.

import Foundation
import GRDB

public enum BrainSchema {
    public static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("v2-brain-consolidator") { db in
            // Memoria bi-temporal (§5.3).
            try db.execute(sql: """
                CREATE TABLE memory (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    content TEXT NOT NULL,
                    importance INTEGER NOT NULL,
                    source TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    event_at REAL,
                    invalidated_at REAL,
                    invalidation_reason TEXT,
                    revises_id TEXT REFERENCES memory(id),
                    consolidation_cycle INTEGER NOT NULL DEFAULT 0
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_memory_valid ON memory(invalidated_at);")
            try db.execute(sql: "CREATE INDEX idx_memory_cycle ON memory(consolidation_cycle);")

            // FTS5 external-content sincronizada por triggers.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE memory_fts USING fts5(
                    content, content='memory', content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                );
                """)
            try db.execute(sql: """
                CREATE TRIGGER memory_ai AFTER INSERT ON memory BEGIN
                    INSERT INTO memory_fts(rowid, content) VALUES (new.rowid, new.content);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER memory_ad AFTER DELETE ON memory BEGIN
                    INSERT INTO memory_fts(memory_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER memory_au AFTER UPDATE ON memory BEGIN
                    INSERT INTO memory_fts(memory_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
                    INSERT INTO memory_fts(rowid, content) VALUES (new.rowid, new.content);
                END;
                """)

            // Embeddings on-device ([Float32] little-endian). embedder_rev invalida
            // vectores si cambia el modelo/OS; el coseno solo compara mismo rev.
            try db.execute(sql: """
                CREATE TABLE memory_embedding (
                    memory_id TEXT PRIMARY KEY REFERENCES memory(id),
                    vector BLOB NOT NULL,
                    dim INTEGER NOT NULL,
                    embedder_rev TEXT NOT NULL
                );
                """)

            // Grafo Zettelkasten entre memorias (refines | contradicts | derives | about | revises).
            try db.execute(sql: """
                CREATE TABLE memory_link (
                    src TEXT NOT NULL,
                    dst TEXT NOT NULL,
                    relation TEXT NOT NULL,
                    PRIMARY KEY (src, dst, relation)
                );
                """)

            // Log de recuperaciones (§5.3): alimenta la reconsolidación (frecuencia)
            // y la heurística de contradicción.
            try db.execute(sql: """
                CREATE TABLE usage_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    turn_ref TEXT NOT NULL,
                    memory_id TEXT NOT NULL,
                    outcome TEXT NOT NULL,
                    ts REAL NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_usage_memory_ts ON usage_log(memory_id, ts);")
            try db.execute(sql: "CREATE INDEX idx_usage_ts ON usage_log(ts);")

            // Cola de candidatos: el AgentLoop encola hechos declarados por el dueño
            // en caliente; el Consolidator los procesa offline (nunca escribe directo).
            try db.execute(sql: """
                CREATE TABLE consolidation_inbox (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT,
                    text TEXT NOT NULL,
                    source TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    cycle INTEGER,
                    consolidated_at REAL
                );
                """)

            // Estado del ciclo (reanudable): una fila por ciclo con su etapa actual.
            try db.execute(sql: """
                CREATE TABLE consolidation_cycle (
                    cycle INTEGER PRIMARY KEY,
                    stage TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL
                );
                """)
            // Destilados de la etapa b, persistidos para reanudar en la c.
            try db.execute(sql: """
                CREATE TABLE cycle_distilled (
                    cycle INTEGER NOT NULL,
                    idx INTEGER NOT NULL,
                    candidate_json TEXT NOT NULL,
                    decided INTEGER NOT NULL DEFAULT 0,
                    decision TEXT,
                    PRIMARY KEY (cycle, idx)
                );
                """)
            // Reflection del ciclo (§5.4 etapa 5): qué aprendió. Fase 3 alimentará el SelfModel.
            try db.execute(sql: """
                CREATE TABLE cycle_log (
                    cycle INTEGER PRIMARY KEY,
                    report_json TEXT NOT NULL,
                    ts REAL NOT NULL
                );
                """)
            // Metadatos del Consolidator (n de ciclos exitosos, último ciclo).
            try db.execute(sql: """
                CREATE TABLE consolidation_meta (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)
        }
    }
}
