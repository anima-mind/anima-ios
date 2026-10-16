// MemoryRestoreV22.swift — la migración v22-memory-owner-restore (campo: "no hay
// forma de una memoria invalidada reanudarla"). `owner_restored_at` marca la
// última vez que el dueño restauró la memoria: el sueño no la vuelve a invalidar
// ni a reconsolidar salvo evidencia nueva del dueño posterior a esa fecha.
// `memory_event` es el historial de decisiones del dueño sobre cada versión
// ("restaurada por el dueño · fecha"). Aditiva: columnas NULL y una tabla nueva,
// sin backfill. NO editar: si cambia, va en otra migración.

import Foundation
import GRDB

enum MemoryRestoreV22 {
    static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("v22-memory-owner-restore") { db in
            try db.execute(sql: "ALTER TABLE memory ADD COLUMN owner_restored_at REAL NULL")
            try db.execute(sql: """
                CREATE TABLE memory_event (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    memory_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    detail TEXT,
                    ts REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_memory_event_memory ON memory_event(memory_id, ts)")
        }
    }
}
