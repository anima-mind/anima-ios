// SelfModelSchema.swift — migración GRDB v3 del SelfModel (§5.5). El self vive en
// una única fila (id=1); su historial de cambios es append-only (qué cambió,
// cuándo, por qué, origen). Los cambios identitarios pendientes del Otro viven en
// self_pending_approval con timeout (expires_at). Protected path: solo el
// SelfModel escribe estas tablas; ninguna tool del Sensorimotor las alcanza.

import Foundation
import GRDB

public enum SelfModelSchema {
    public static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("v3-self-model") { db in
            try db.execute(sql: """
                CREATE TABLE self_model (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    view_json TEXT NOT NULL,
                    cycles INTEGER NOT NULL DEFAULT 0,
                    born_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE TABLE self_change (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    field TEXT NOT NULL,
                    before_value TEXT,
                    after_value TEXT NOT NULL,
                    rationale TEXT,
                    origin TEXT NOT NULL,
                    ts REAL NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE TABLE self_pending_approval (
                    id TEXT PRIMARY KEY,
                    field TEXT NOT NULL,
                    before_value TEXT,
                    after_value TEXT NOT NULL,
                    rationale TEXT,
                    origin TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    resolved_at REAL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_pending_status ON self_pending_approval(status, expires_at);")
        }
    }
}
