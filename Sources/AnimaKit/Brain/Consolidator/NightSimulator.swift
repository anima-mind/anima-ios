// NightSimulator.swift — "Simular una noche" (Ajustes → Mente, components.md).
// Corre UN ciclo del Consolidator en foreground para ver Memoria/Metas poblarse
// sin esperar al BGProcessingTask nocturno, y lo resume en una línea.

import Foundation

public actor NightSimulator {
    public static let nothingNew = "Nada nuevo que consolidar."

    private let consolidator: Consolidator
    private let goalCount: @Sendable () async -> Int
    private var running = false

    public init(consolidator: Consolidator, goalCount: @escaping @Sendable () async -> Int = { 0 }) {
        self.consolidator = consolidator
        self.goalCount = goalCount
    }

    /// Corre el ciclo y devuelve el resumen ("ciclo #N — M memorias nuevas, K metas").
    /// nil si ya hay uno corriendo (la fila queda deshabilitada mientras tanto).
    public func run() async -> String? {
        guard !running else { return nil }
        running = true
        defer { running = false }
        let goalsBefore = await goalCount()
        do {
            let report = try await consolidator.cycle()
            let goals = max(0, await goalCount() - goalsBefore)
            return Self.summary(report, newGoals: goals)
        } catch {
            return "El ciclo no pudo completarse: \(error)"
        }
    }

    public static func summary(_ report: Consolidator.CycleReport, newGoals: Int) -> String {
        guard report.distilled > 0 || report.added > 0 || report.updated > 0 || newGoals > 0 else {
            return "ciclo #\(report.cycle) — \(nothingNew)"
        }
        let memories = report.added == 1 ? "1 memoria nueva" : "\(report.added) memorias nuevas"
        let goals = newGoals == 1 ? "1 meta" : "\(newGoals) metas"
        return "ciclo #\(report.cycle) — \(memories), \(goals)"
    }
}
