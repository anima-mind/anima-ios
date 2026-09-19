// RealSchema.swift — migración GRDB v4 del RealRegister (§5.6). Cada fallo se
// acumula por PatternKey con contadores y timestamps; al cruzar el umbral N el
// patrón se marca demanding y entra a la restructure queue. Índices por
// (pattern_key, session_id) y (pattern_key, day) para contar insistencia en SQL.

import Foundation
import GRDB

public enum RealSchema {
    public static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("v4-real-register") { db in
            try db.execute(sql: """
                CREATE TABLE real_failure (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    pattern_key TEXT NOT NULL,
                    tool_name TEXT NOT NULL,
                    error_class TEXT NOT NULL,
                    target TEXT,
                    arg_shape TEXT NOT NULL,
                    session_id TEXT,
                    raw_error TEXT,
                    ts REAL NOT NULL,
                    day TEXT NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_failure_pattern_session ON real_failure(pattern_key, session_id);")
            try db.execute(sql: "CREATE INDEX idx_failure_pattern_day ON real_failure(pattern_key, day);")

            try db.execute(sql: """
                CREATE TABLE real_pattern (
                    pattern_key TEXT PRIMARY KEY,
                    tool_name TEXT NOT NULL,
                    error_class TEXT NOT NULL,
                    target TEXT,
                    first_seen REAL NOT NULL,
                    last_seen REAL NOT NULL,
                    total_count INTEGER NOT NULL DEFAULT 0,
                    status TEXT NOT NULL DEFAULT 'active',
                    resolved_at REAL
                );
                """)

            try db.execute(sql: """
                CREATE TABLE restructure_queue (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    pattern_key TEXT NOT NULL,
                    request_json TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    created_at REAL NOT NULL,
                    resolved_at REAL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_restructure_status ON restructure_queue(status);")
        }
    }
}
