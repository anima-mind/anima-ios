import Foundation
import Testing
@testable import AnimaKit

@Suite struct SkillEngineTests {

    /// Escribe un dir sandbox con un skill markdown portable.
    private func makeSkillsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = """
        ---
        name: resumen-manana
        when: resumen de mañana, qué tengo agendado, agenda del día, pendientes
        steps:
          - calendar.list(days_ahead=1)
          - reminders.list()
          - reminders.create(title=preparar día)
        ---
        Arma el resumen del día siguiente.
        """
        try md.write(to: dir.appendingPathComponent("resumen.md"), atomically: true, encoding: .utf8)
        return dir
    }

    private func makeEngine(dir: URL) throws -> SkillEngine {
        SkillEngine(queue: try AnimaDatabase.temporary(), directory: dir)
    }

    @Test func matchesSkillByTriggerOverlap() async throws {
        let engine = try makeEngine(dir: try makeSkillsDir())
        let match = await engine.match("dame el resumen de mañana por favor")
        #expect(match?.name == "resumen-manana")
        #expect(match?.steps.count == 3)
    }

    @Test func noMatchWhenUnrelated() async throws {
        let engine = try makeEngine(dir: try makeSkillsDir())
        #expect(await engine.match("cuál es la capital de Francia") == nil)
    }

    @Test func threeConsecutiveSuccessesMarkPracticed() async throws {
        let engine = try makeEngine(dir: try makeSkillsDir())
        await engine.practice("resumen-manana", success: true)
        await engine.practice("resumen-manana", success: true)
        #expect(!(await engine.isPracticed("resumen-manana")))
        await engine.practice("resumen-manana", success: true)
        #expect(await engine.isPracticed("resumen-manana"))
        let stats = await engine.stats("resumen-manana")
        #expect(stats?.totalSuccess == 3)
        #expect(stats?.successStreak == 3)
    }

    @Test func failureResetsStreakAndDeautomatizes() async throws {
        let engine = try makeEngine(dir: try makeSkillsDir())
        for _ in 0..<3 { await engine.practice("resumen-manana", success: true) }
        #expect(await engine.isPracticed("resumen-manana"))
        await engine.practice("resumen-manana", success: false)   // lo Real insiste
        #expect(!(await engine.isPracticed("resumen-manana")))
        #expect(await engine.stats("resumen-manana")?.successStreak == 0)
    }

    @Test func automatizeSeparatesEfferentSteps() async throws {
        let engine = try makeEngine(dir: try makeSkillsDir())
        #expect(await engine.automatize("resumen-manana") == nil)   // aún no practiced
        for _ in 0..<3 { await engine.practice("resumen-manana", success: true) }
        let compiled = try #require(await engine.automatize("resumen-manana"))
        // Los aferentes se automatizan; el eferente (reminders.create) SIEMPRE pide ok.
        #expect(compiled.afferentSteps.contains("calendar.list(days_ahead=1)"))
        #expect(compiled.efferentSteps.contains("reminders.create(title=preparar día)"))
        #expect(!compiled.afferentSteps.contains { $0.hasPrefix("reminders.create") })
    }
}
