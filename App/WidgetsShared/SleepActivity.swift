// SleepActivity.swift — Live Activity del sueño en foreground (fallback al
// abrir tras >48 h sin ciclo, o "Simular una noche"): "Budosky está
// consolidando…" → "Noche #N lista". Atributos compartidos app ↔ extensión.

import ActivityKit
import Foundation

struct SleepActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable { case consolidating, done, interrupted }
        var phase: Phase
        /// Número de la noche al terminar (ciclos completos).
        var night: Int
    }

    var selfName: String
}
