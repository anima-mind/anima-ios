// GoalLifecycleV21.swift — la migración v21-goal-lifecycle (campo: "le dije que
// ya no quería ahorrar sino abonar a la deuda y en el sueño quedaron las dos").
// Una meta se puede dejar o reemplazar: `superseded_by` apunta a la que la
// reemplazó, `abandoned_at` fecha el abandono y `declared_at` la última vez que
// el dueño la declaró (o la reactivó). El sueño compara contra esas fechas: lo
// último que dijo el dueño gana. Solo columnas y backfill por SQL — no adivina
// reemplazos en los datos existentes. NO editar: si cambia, va en otra migración.

import Foundation
import GRDB

enum GoalLifecycleV21 {
    static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("v21-goal-lifecycle") { db in
            try db.execute(sql: "ALTER TABLE goal ADD COLUMN superseded_by TEXT NULL")
            try db.execute(sql: "ALTER TABLE goal ADD COLUMN abandoned_at REAL NULL")
            try db.execute(sql: "ALTER TABLE goal ADD COLUMN declared_at REAL NULL")
            try db.execute(sql: "UPDATE goal SET declared_at = created_at")
            try db.execute(sql: "UPDATE goal SET abandoned_at = updated_at WHERE status = 'abandoned'")
        }
    }
}
