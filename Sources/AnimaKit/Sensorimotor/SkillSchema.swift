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
    }
}
