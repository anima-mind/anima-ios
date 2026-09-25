import Foundation
import Testing
@testable import AnimaKit

@Suite struct ObservablePredicateTests {

    @Test func everyPredicateEvaluatesBothWays() async {
        let slot = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3600)
        let full = MockObservableEnvironment(workouts: 1, overdue: 5, sleep: 6.5, slots: [slot], mentions: ["inglés": 3])
        let empty = MockObservableEnvironment()

        let overdue = ObservablePredicate.remindersOverdue(atMost: 2)
        #expect(await overdue.evaluate(in: full)
                == ObservableReading(satisfied: false, detail: "recordatorios vencidos: 5 (máximo 2)"))
        #expect(await overdue.evaluate(in: empty).satisfied)

        let sleep = ObservablePredicate.sleepHours(atLeast: 7, lastDays: 7)
        #expect(await sleep.evaluate(in: full)
                == ObservableReading(satisfied: false, detail: "sueño promedio 6.5h (meta 7.0h)"))
        // Sin datos de sueño no se presiona (no hay evidencia de brecha).
        #expect(await sleep.evaluate(in: empty) == ObservableReading(satisfied: true, detail: "sin datos de sueño"))

        let freeSlot = ObservablePredicate.calendarFreeSlot(minMinutes: 60, withinDays: 3)
        #expect(await freeSlot.evaluate(in: full)
                == ObservableReading(satisfied: true, detail: "1 huecos de 60min disponibles"))
        #expect(await freeSlot.evaluate(in: empty)
                == ObservableReading(satisfied: false, detail: "sin huecos de 60min en 3 días"))

        let mention = ObservablePredicate.daysSinceLastMention(topic: "inglés", atMost: 2)
        #expect(await mention.evaluate(in: full)
                == ObservableReading(satisfied: false, detail: "3 días desde 'inglés' (máximo 2)"))
        #expect(await mention.evaluate(in: empty)
                == ObservableReading(satisfied: false, detail: "nunca se mencionó 'inglés'"))
    }

    @Test func labelsAreHumanReadable() {
        #expect(ObservablePredicate.workoutsPerWeek(atLeast: 3).label == "entrenar al menos 3x por semana")
        #expect(ObservablePredicate.remindersOverdue(atMost: 0).label == "no más de 0 recordatorios vencidos")
        #expect(ObservablePredicate.sleepHours(atLeast: 7.5, lastDays: 5).label == "dormir al menos 7.5h (últimos 5 días)")
        #expect(ObservablePredicate.calendarFreeSlot(minMinutes: 30, withinDays: 2).label
                == "reservar un hueco de 30min en 2 días")
        #expect(ObservablePredicate.daysSinceLastMention(topic: "guitarra", atMost: 4).label
                == "retomar 'guitarra' cada 4 días")
    }

    @Test func decodingDefaultsAndUnknownKinds() throws {
        func decode(_ json: String) throws -> ObservablePredicate {
            try JSONDecoder().decode(ObservablePredicate.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"kind":"sleep_hours_at_least","hours":7}"#) == .sleepHours(atLeast: 7, lastDays: 7))
        #expect(try decode(#"{"kind":"calendar_has_free_slot","min_minutes":45}"#)
                == .calendarFreeSlot(minMinutes: 45, withinDays: 7))
        #expect(try decode(#"{"kind":"days_since_last_mention_at_most","topic":"x"}"#)
                == .daysSinceLastMention(topic: "x", atMost: 7))
        // Enum cerrado: un kind inventado por el modelo NO se acepta.
        #expect(throws: DecodingError.self) { _ = try decode(#"{"kind":"meditate_daily","value":1}"#) }
    }
}

@Suite struct PatternKeyErrorTaxonomyTests {

    @Test func toolResultTextMapsToTaxonomy() {
        #expect(PatternKey.errorClass(fromToolResult: "Acción no permitida por la política") == "permission_denied")
        #expect(PatternKey.errorClass(fromToolResult: "Permission denied") == "permission_denied")
        #expect(PatternKey.errorClass(fromToolResult: "La nota 'x' no encontrada") == "not_found")
        #expect(PatternKey.errorClass(fromToolResult: "La operación excedió el tiempo") == "timeout")
        #expect(PatternKey.errorClass(fromToolResult: "request timed out") == "timeout")
        #expect(PatternKey.errorClass(fromToolResult: "Error: 'start' inválido (usa ISO 8601).") == "invalid_input")
        #expect(PatternKey.errorClass(fromToolResult: "disco lleno") == "os_error")
    }

    @Test func classifiedErrorsMapToTaxonomy() {
        #expect(PatternKey.errorClass(from: .rateLimited(after: 3)) == "rate_limited")
        #expect(PatternKey.errorClass(from: .retryable(after: nil)) == "retryable")
        #expect(PatternKey.errorClass(from: .contextOverflow) == "context_overflow")
        #expect(PatternKey.errorClass(from: .fatal(status: 401, message: "x")) == "fatal")
    }

    @Test func loopFailuresCollapseVolatileArgs() {
        let now = Date()
        let a = Failure.loop(name: "calendar", input: .object(["action": .string("search"), "query": .string("dentista"),
                                                                "calendar": .string("Trabajo")]),
                             sessionId: "s1", now: now)
        let b = Failure.loop(name: "calendar", input: .object(["action": .string("search"), "query": .string("médico"),
                                                                "calendar": .string("Trabajo")]),
                             sessionId: "s2", now: now)
        #expect(a.pattern.errorClass == "loop_detected")
        #expect(a.pattern.targetResource == "Trabajo")
        #expect(a.pattern.key == b.pattern.key)  // misma estrategia insistente → misma clave
        #expect(a.rawError == "loop detected")
    }

    @Test func classifiedFailureHasNoArgsOrTarget() {
        let f = Failure.classified(toolName: "provider", error: .fatal(status: 400, message: "bad"),
                                   sessionId: nil, now: Date())
        #expect(f.pattern.argShape == "<call>")
        #expect(f.pattern.errorClass == "fatal")
        #expect(f.pattern.targetResource == nil)
        #expect(f.rawError.contains("400"))
    }
}
