import Foundation
import Testing
@testable import AnimaKit

/// Micro-benchmark concurrente de las heurísticas de la cita (opt-in
/// ANIMA_REGEX_BENCH=1), como el de #45: 8 tareas × N vueltas en el pool
/// cooperativo. Imprime `[regex-bench] … ms`.
@Suite struct QuoteRegexBenchTests {
    static let phrases = QuotedLocalToolsTests.neverAct + [
        "pásalo para el viernes 23 en la tarde", "ya lo pagué", "listo", "no lo he hecho", "mañana a las 5",
        "el viernes 3 de noviembre", "¿qué tengo pendiente el viernes 22?", "el lunes 8 por la mañana",
    ]

    /// Solo las heurísticas que agregó este PR (sin times()/explicitDate de main).
    static func mine() -> Int {
        let now = ProactiveFixtures.date(2026, 10, 15, 19)
        var hits = 0
        for phrase in phrases {
            hits += LocalToolAdapter.quotedReminderIntent(phrase).count
            let when = LocalWhen(now: now, calendar: ProactiveFixtures.calendar, ownerText: phrase)
            let folded = LocalWhen.fold(phrase)
            if when.weekdayWithDay(folded) != nil { hits += 1 }
            if when.explicitWeekdayMismatch(folded) { hits += 1 }
            if ChatQuoteContext.withoutEcho(phrase) != nil { hits += 1 }
        }
        return hits
    }

    static func work() -> Int {
        let now = ProactiveFixtures.date(2026, 10, 15, 19)
        var hits = 0
        for phrase in phrases {
            hits += LocalToolAdapter.quotedReminderIntent(phrase).count
            let when = LocalWhen(now: now, calendar: ProactiveFixtures.calendar, ownerText: phrase)
            if when.ownerDay != nil { hits += 1 }
            if when.ownerMentionsTime { hits += 1 }
            if when.dayIsAmbiguous { hits += 1 }
            if when.ambiguousDayQuestion != nil { hits += 1 }
        }
        return hits
    }

    // Opt-in como trait: sin el env var ni se agenda (no ocupa el pool).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANIMA_REGEX_BENCH"] == "1"))
    func concurrentHeuristics() async {
        let rounds = Int(ProcessInfo.processInfo.environment["ANIMA_REGEX_ROUNDS"] ?? "") ?? 40
        let start = Date()
        let total = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 { group.addTask { (0..<rounds).reduce(0) { acc, _ in acc + Self.work() } } }
            return await group.reduce(0, +)
        }
        let ms = Date().timeIntervalSince(start) * 1000
        print("[regex-bench] completo: 8 tareas × \(rounds) vueltas × \(Self.phrases.count) frases: \(Int(ms)) ms (hits \(total))")
        #expect(total > 0)
        let start2 = Date()
        let mine = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 { group.addTask { (0..<rounds).reduce(0) { acc, _ in acc + Self.mine() } } }
            return await group.reduce(0, +)
        }
        print("[regex-bench] del PR: 8 tareas × \(rounds) vueltas × \(Self.phrases.count) frases: \(Int(Date().timeIntervalSince(start2) * 1000)) ms (hits \(mine))")
    }
}
