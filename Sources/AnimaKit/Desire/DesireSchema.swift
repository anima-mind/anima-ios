// DesireSchema.swift — migración GRDB v5 del deseo (§5.8). El modelo del Otro
// (Goals con fuente, precedencia y estado) y el log auditable de Intentions viven
// aquí. Constraint dura (eval C.3 #4): cada Intention referencia un Goal
// (goal_id NOT NULL REFERENCES goal(id)) → CERO Intentions huérfanas. GRDB activa
// PRAGMA foreign_keys por defecto, así que la FK se aplica en runtime.
// Protected path: solo OtherModel/DesireEngine escriben estas tablas.

import Foundation
import GRDB

public enum DesireSchema {
    public static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("v5-desire") { db in
            // El deseo del dueño. desired_state = predicado observable tipado (JSON
            // del enum cerrado). source: stated|inferred|structural (precedencia dura).
            // status: active|achieved|abandoned|pending_confirmation.
            try db.execute(sql: """
                CREATE TABLE goal (
                    id TEXT PRIMARY KEY,
                    statement TEXT NOT NULL,
                    predicate_json TEXT NOT NULL,
                    source TEXT NOT NULL,
                    status TEXT NOT NULL,
                    priority INTEGER NOT NULL DEFAULT 5,
                    evidence TEXT NOT NULL DEFAULT '',
                    confirmed_by_other INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_goal_status ON goal(status, source);")

            // Log auditable de Intentions. goal_id NOT NULL + FK = eval #4.
            try db.execute(sql: """
                CREATE TABLE intention (
                    id TEXT PRIMARY KEY,
                    goal_id TEXT NOT NULL REFERENCES goal(id),
                    observables_json TEXT NOT NULL,
                    gap TEXT NOT NULL,
                    proposed_text TEXT NOT NULL,
                    outcome TEXT NOT NULL DEFAULT 'pending',
                    created_at REAL NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_intention_goal ON intention(goal_id, created_at);")
            try db.execute(sql: "CREATE INDEX idx_intention_outcome ON intention(outcome, created_at);")

            // Presupuesto del pulso (§5.8): ≤4 pulsos/día. Una fila por pulso que
            // produjo una Intention; el conteo por día impone el tope.
            try db.execute(sql: """
                CREATE TABLE desire_pulse (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL,
                    day TEXT NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_pulse_day ON desire_pulse(day);")
        }
    }
}
