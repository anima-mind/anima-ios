// SkillSchema.swift — migración GRDB v6 del SkillEngine (§5.7). Los skills viven
// como markdown portable en un dir sandbox; aquí solo su práctica: contadores de
// éxito/fallo por skill y el flag `practiced` (≥3 éxitos seguidos). La
// desautomatización dirigida por lo Real resetea el streak al primer fallo.

import Foundation
import GRDB

public enum SkillSchema {
    public static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("v6-skill") { db in
            try db.execute(sql: """
                CREATE TABLE skill_practice (
                    skill_name TEXT PRIMARY KEY,
                    success_streak INTEGER NOT NULL DEFAULT 0,
                    total_success INTEGER NOT NULL DEFAULT 0,
                    total_fail INTEGER NOT NULL DEFAULT 0,
                    practiced INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                );
                """)
        }
        // Cableado del SkillEngine al turno: toggle por skill (Ajustes) y la
        // telemetría de match/inyección/outcome por turno (eval futuro: ¿ayudan?).
        m.registerMigration("v7-skill-wiring") { db in
            try db.execute(sql: "ALTER TABLE skill_practice ADD COLUMN disabled INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: """
                CREATE TABLE skill_turn_telemetry (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    skill_name TEXT,
                    score REAL,
                    injected_chars INTEGER NOT NULL DEFAULT 0,
                    truncated INTEGER NOT NULL DEFAULT 0,
                    outcome TEXT NOT NULL,
                    end_reason TEXT NOT NULL,
                    skill_tool_calls INTEGER NOT NULL DEFAULT 0,
                    skill_tool_errors INTEGER NOT NULL DEFAULT 0,
                    ts REAL NOT NULL
                );
                """)
        }
    }
}
