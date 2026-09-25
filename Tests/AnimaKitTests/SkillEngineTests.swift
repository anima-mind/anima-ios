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
        #expect(await engine.automatize("resumen-manana") == nil)   // aún no automatized
        for _ in 0..<5 { await engine.practice("resumen-manana", success: true) }
        let compiled = try #require(await engine.automatize("resumen-manana"))
        // Los aferentes se automatizan; el eferente (reminders.create) JAMÁS se auto-ejecuta.
        #expect(compiled.afferentSteps == ["calendar.list(days_ahead=1)", "reminders.list()"])
        #expect(compiled.efferentSteps == ["reminders.create(title=preparar día)"])
        #expect(compiled.skill.name == "resumen-manana")
    }

    /// K=5 (§5.7/§B.6): racha 3 = practiced (visible) pero NO automatiza; 5 sí;
    /// un fallo resetea todo el arco.
    @Test func kFiveAutomatizesAndPracticedThreeDoesNot() async throws {
        let engine = try makeEngine(dir: try makeSkillsDir())
        #expect(SkillEngine.defaultAutomatizeThreshold == 5)
        #expect(SkillEngine.defaultPracticeThreshold == 3)
        for _ in 0..<3 { await engine.practice("resumen-manana", outcome: .success) }
        #expect(await engine.isPracticed("resumen-manana"))
        #expect(!(await engine.isAutomatized("resumen-manana")))
        #expect(await engine.stats("resumen-manana")?.level == .practiced)
        #expect(await engine.automatize("resumen-manana") == nil)
        await engine.practice("resumen-manana", outcome: .success)
        #expect(await engine.automatize("resumen-manana") == nil)   // 4 tampoco
        await engine.practice("resumen-manana", outcome: .success)
        #expect(await engine.isAutomatized("resumen-manana"))
        #expect(await engine.stats("resumen-manana")?.level == .automatized)
        #expect(await engine.overview().first?.automatized == true)
        #expect(await engine.automatize("resumen-manana") != nil)

        await engine.practice("resumen-manana", outcome: .failure)
        #expect(!(await engine.isAutomatized("resumen-manana")))
        #expect(await engine.stats("resumen-manana")?.level == .learned)
        #expect(await engine.automatize("resumen-manana") == nil)
    }

    @Test func deautomatizeReturnsToDeclarative() async throws {
        let engine = try makeEngine(dir: try makeSkillsDir())
        for _ in 0..<5 { await engine.practice("resumen-manana", outcome: .success) }
        await engine.deautomatize("resumen-manana")
        #expect(await engine.stats("resumen-manana")?.level == .learned)
        #expect(SkillLevel.learned < .practiced && SkillLevel.practiced < .automatized)
    }

    /// Lista eferente corregida contra el `operation(for:)` de las tools reales.
    @Test func efferentClassificationMatchesRealTools() {
        // notes.create es la operación real (no existe notes.write): eferente.
        #expect(SkillEngine.isEfferent(step: "notes.create(name=x, content)"))
        #expect(SkillEngine.isEfferent(step: "notes.append(name=diario-{hoy}, content)"))
        // calendar.search solo lee: aferente.
        #expect(!SkillEngine.isEfferent(step: "calendar.search(query=Ana)"))
        #expect(!SkillEngine.isEfferent(step: "calendar.list(days_ahead=7)"))
        #expect(!SkillEngine.isEfferent(step: "notes.read(name=x)"))
        #expect(!SkillEngine.isEfferent(step: "notes.list()"))
        #expect(!SkillEngine.isEfferent(step: "reminders.list()"))
        #expect(!SkillEngine.isEfferent(step: "phone_context.health(days=1)"))
        for step in ["calendar.create(title)", "calendar.delete(event_id)", "reminders.create(title)",
                     "reminders.complete(reminder_id)", "camera.capture_photo()", "audio.record()"] {
            #expect(SkillEngine.isEfferent(step: step), "\(step)")
        }
        // Fail-closed: lo desconocido o en prosa NUNCA se auto-ejecuta.
        #expect(SkillEngine.isEfferent(step: "notes.write(name=x)"))
        #expect(SkillEngine.isEfferent(step: "web_search(query=x)"))
        #expect(SkillEngine.isEfferent(step: "revisa la agenda"))
        #expect(SkillEngine.isEfferent(step: "calendar.list.extra()"))
        // Cada operación listada corresponde a una operación real de su tool.
        let real: [String: any SensorimotorTool] = ["calendar": CalendarTool(), "reminders": RemindersTool(),
                                                    "notes": NotesTool(root: FileManager.default.temporaryDirectory),
                                                    "phone_context": PhoneContextTool()]
        func actions(_ tool: any SensorimotorTool) -> Set<String> {
            guard case .client(_, _, let schema) = tool.spec,
                  case .array(let values)? = schema["properties"]?["action"]?["enum"] else { return [] }
            return Set(values.compactMap(\.stringValue))
        }
        for key in SkillEngine.afferentOperations.union(SkillEngine.efferentOperations) {
            let parts = key.split(separator: ".").map(String.init)
            guard let tool = real[parts[0]] else { continue }   // camera/audio: operación fija
            let input: JSONValue = .object(["action": .string(parts[1])])
            #expect(actions(tool).contains(parts[1]), "\(key) no es una acción real")
            #expect(tool.operation(for: input) == parts[1])
            // La policy coincide salvo notes (libreta propia: allow aun al escribir).
            if parts[0] != "notes" {
                #expect(tool.kind(for: input) == (SkillEngine.afferentOperations.contains(key) ? .afferent : .efferent))
            }
        }
        #expect(CameraTool().operation(for: .null) == "capture_photo")
        #expect(AudioTool().operation(for: .null) == "record")
    }
}

#if canImport(SwiftUI)
@Suite struct SkillsSettingsStatusTests {
    @Test @MainActor func statusShowsThreeLevels() {
        func row(_ level: SkillLevel, _ n: Int) -> SkillOverview {
            SkillOverview(name: "x", summary: "", level: level, totalSuccess: n, totalFail: 0,
                          successStreak: n, disabled: false)
        }
        #expect(SkillsViewModel.status(row(.learned, 0)) == "aprendida · 0 éxitos")
        #expect(SkillsViewModel.status(row(.practiced, 3)) == "practicada · 3 éxitos")
        #expect(SkillsViewModel.status(row(.automatized, 1)) == "automatizada · 1 éxito")
    }
}
#endif
