// ProactiveSchema.swift — migración v12 de la capa proactiva: recordatorios
// PERSONALES de Anima (los entrega ella, ≠ EventKit), cadencia de check-in por
// meta y su log, y el origen de cada Intention (pulso al abrir vs background).
// Todo lo que se notifica se fija al crear: al disparar no hay LLM.

import Foundation
import GRDB

public enum ProactiveSchema {
    public static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("v12-proactive") { db in
            // repeat: none|daily|weekdays|weekly. status: scheduled|fired|done|cancelled.
            // Un recordatorio que se repite sigue `scheduled`: fire_at avanza a la
            // próxima ocurrencia cada vez que se entrega.
            try db.execute(sql: """
                CREATE TABLE anima_reminder (
                    id TEXT PRIMARY KEY,
                    text TEXT NOT NULL,
                    fire_at REAL NOT NULL,
                    repeat TEXT NOT NULL DEFAULT 'none',
                    goal_id TEXT NULL REFERENCES goal(id),
                    status TEXT NOT NULL,
                    origin_session_id TEXT,
                    created_at REAL NOT NULL,
                    fired_at REAL NULL,
                    done_at REAL NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_anima_reminder_status ON anima_reminder(status, fire_at);")
            try db.execute(sql: "CREATE INDEX idx_anima_reminder_fire ON anima_reminder(fire_at);")

            // Check-in por meta (opt-in): cadence none|daily|weekdays|weekly a HH:mm
            // local; weekday 1=domingo…7=sábado (solo weekly).
            try db.execute(sql: "ALTER TABLE goal ADD COLUMN checkin_cadence TEXT NOT NULL DEFAULT 'none'")
            try db.execute(sql: "ALTER TABLE goal ADD COLUMN checkin_hour INTEGER NOT NULL DEFAULT 20")
            try db.execute(sql: "ALTER TABLE goal ADD COLUMN checkin_minute INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE goal ADD COLUMN checkin_weekday INTEGER NULL")

            // answer: yes|partial|no|skipped; NULL = preguntado sin respuesta.
            try db.execute(sql: """
                CREATE TABLE goal_checkin (
                    id TEXT PRIMARY KEY,
                    goal_id TEXT NOT NULL REFERENCES goal(id),
                    asked_at REAL NOT NULL,
                    answered_at REAL NULL,
                    answer TEXT NULL,
                    note TEXT NOT NULL DEFAULT ''
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_goal_checkin_goal ON goal_checkin(goal_id, asked_at);")

            try db.execute(sql: "ALTER TABLE intention ADD COLUMN origin TEXT NOT NULL DEFAULT 'foreground'")
        }
    }
}
