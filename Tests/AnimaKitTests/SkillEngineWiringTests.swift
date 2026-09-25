import Foundation
import GRDB
import Testing
@testable import AnimaKit

// MARK: - Fixtures

enum SkillFixtures {
    static let agendar = """
    ---
    name: agendar-con-contexto
    description: Crea eventos en el calendario revisando antes conflictos
    when: agendar reunión, crear evento, programar cita o llamada
    requires_tools: [calendar]
    steps:
      - calendar.list(days_ahead=7)
      - calendar.create(title, start, end)
    ---
    Revisa conflictos antes de crear.
    """

    static let nota = """
    ---
    name: nota-diaria
    description: Lleva una nota diaria con lo importante del día
    when: nota diaria, apunta en el diario, bitácora
    requires_tools:
      - notes
    steps:
      - notes.read(name=diario)
      - notes.append(name=diario, content)
    ---
    Una sola nota por día; agrega, no sobrescribas.
    """

    static let resumen = """
    ---
    name: resumen-manana
    when: resumen de mañana, agenda del día, pendientes
    steps: calendar.list(days_ahead=1), reminders.list()
    ---
    """

    static func dir(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skills-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in files {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    static func standard() throws -> URL {
        try dir(["agendar.md": agendar, "nota.md": nota, "resumen.md": resumen])
    }

    /// Los seeds reales que el shell copia al primer arranque (App/Skills).
    static var seedsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Skills")
    }
}

// MARK: - Match determinista

@Suite struct SkillMatchTests {
    private func engine(_ dir: URL) throws -> SkillEngine {
        SkillEngine(queue: try AnimaDatabase.temporary(), directory: dir)
    }

    @Test func turnMatchesTheRightSkill() async throws {
        let e = try engine(try SkillFixtures.standard())
        #expect(await e.bestMatch("agéndame una reunión con Ana el jueves")?.skill.name == "agendar-con-contexto")
        #expect(await e.bestMatch("apunta esto en mi nota diaria")?.skill.name == "nota-diaria")
        #expect(await e.bestMatch("dame el resumen de mañana")?.skill.name == "resumen-manana")
    }

    @Test func unrelatedTurnMatchesNothing() async throws {
        let e = try engine(try SkillFixtures.standard())
        #expect(await e.bestMatch("cuál es la capital de Francia") == nil)
        #expect(await e.bestMatch("hola, ¿cómo estás?") == nil)
        #expect(await e.bestMatch("") == nil)
    }

    @Test func matchIsDeterministicAndScored() async throws {
        let e = try engine(try SkillFixtures.standard())
        let a = try #require(await e.bestMatch("programar una llamada"))
        let b = try #require(await e.bestMatch("programar una llamada"))
        #expect(a == b)
        #expect(a.score >= SkillEngine.matchThreshold)
        #expect(a.overlap == 2)
    }

    /// Empate exacto de score y overlap: gana el nombre menor (orden total).
    @Test func tieBreaksByName() async throws {
        let twin = { (name: String) in "---\nname: \(name)\nwhen: tarea gemela\n---\n" }
        let e = try engine(try SkillFixtures.dir(["b.md": twin("zeta"), "a.md": twin("alfa")]))
        #expect(await e.bestMatch("tarea gemela")?.skill.name == "alfa")
    }

    /// Un token compartido por varios gatillos pesa menos (1/df) que uno propio.
    @Test func specificTokenWinsOverShared() async throws {
        let e = try engine(try SkillFixtures.dir([
            "x.md": "---\nname: x\nwhen: agenda semanal revisar\n---\n",
            "y.md": "---\nname: y\nwhen: agenda viaje vuelo\n---\n",
        ]))
        #expect(await e.bestMatch("agenda del vuelo")?.skill.name == "y")
    }

    @Test func disabledSkillNeverMatches() async throws {
        let e = try engine(try SkillFixtures.standard())
        await e.setDisabled("nota-diaria", true)
        #expect(await e.isDisabled("nota-diaria"))
        #expect(await e.bestMatch("apunta en mi nota diaria")?.skill.name != "nota-diaria")
        await e.setDisabled("nota-diaria", false)
        #expect(await e.bestMatch("apunta en mi nota diaria")?.skill.name == "nota-diaria")
    }

    @Test func missingRequiredToolExcludesSkill() async throws {
        let e = try engine(try SkillFixtures.standard())
        #expect(await e.bestMatch("apunta en mi nota diaria", availableTools: ["calendar"]) == nil)
        #expect(await e.bestMatch("apunta en mi nota diaria", availableTools: ["notes"])?.skill.name == "nota-diaria")
    }

    @Test func noDirectoryMeansNoSkills() async throws {
        let e = SkillEngine(queue: try AnimaDatabase.temporary())
        #expect(await e.loadSkills().isEmpty)
        #expect(await e.bestMatch("agendar reunión") == nil)
    }

    @Test func seedSkillsParseAndMatch() async throws {
        let e = try engine(SkillFixtures.seedsDir)
        let names = await e.loadSkills().map(\.name)
        #expect(names == ["agendar-con-contexto", "nota-diaria"])
        #expect(await e.bestMatch("agenda una reunión con Laura mañana a las 3")?.skill.name == "agendar-con-contexto")
        #expect(await e.bestMatch("anota en la bitácora que terminé el informe")?.skill.name == "nota-diaria")
    }
}

// MARK: - Parseo del formato portable

@Suite struct SkillParseTests {
    @Test func parsesDoc05FrontMatter() throws {
        let skill = try #require(SkillEngine.parse(SkillFixtures.agendar))
        #expect(skill.description.hasPrefix("Crea eventos"))
        #expect(skill.requiresTools == ["calendar"])
        #expect(skill.steps == ["calendar.list(days_ahead=7)", "calendar.create(title, start, end)"])
        #expect(skill.body == "Revisa conflictos antes de crear.")
        #expect(skill.toolNames == ["calendar"])
    }

    @Test func parsesListRequiresAndInlineSteps() throws {
        let nota = try #require(SkillEngine.parse(SkillFixtures.nota))
        #expect(nota.requiresTools == ["notes"])
        let resumen = try #require(SkillEngine.parse(SkillFixtures.resumen))
        #expect(resumen.steps == ["calendar.list(days_ahead=1)", "reminders.list()"])
        #expect(resumen.toolNames == ["calendar", "reminders"])
    }

    @Test func rejectsMissingNameOrFrontMatter() {
        #expect(SkillEngine.parse("sin front-matter") == nil)
        #expect(SkillEngine.parse("---\nname: x\nsin cierre") == nil)
        #expect(SkillEngine.parse("---\nwhen: algo\n---\n") == nil)
    }
}

// MARK: - Practice (reloj + DB efímera)

@Suite struct SkillPracticeTests {
    @Test func outcomesDriveStreakAndPracticed() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_000))
        let queue = try AnimaDatabase.temporary()
        let e = SkillEngine(queue: queue, directory: try SkillFixtures.standard(), now: { clock.value })
        await e.practice("nota-diaria", outcome: .success)
        await e.practice("nota-diaria", outcome: .neutral)     // no toca contadores
        await e.practice("nota-diaria", outcome: .success)
        #expect(!(await e.isPracticed("nota-diaria")))
        clock.mutate { $0 = $0.addingTimeInterval(60) }
        await e.practice("nota-diaria", outcome: .success)
        #expect(await e.isPracticed("nota-diaria"))
        let updated = try await queue.read { db in
            try Double.fetchOne(db, sql: "SELECT updated_at FROM skill_practice WHERE skill_name='nota-diaria'")
        }
        #expect(updated == 1_060)

        await e.practice("nota-diaria", outcome: .failure)     // un fallo resetea
        let stats = try #require(await e.stats("nota-diaria"))
        #expect(stats.successStreak == 0)
        #expect(!stats.practiced)
        #expect(stats.totalSuccess == 3)
        #expect(stats.totalFail == 1)
    }

    /// Deshabilitar no borra la práctica, y practicar no rehabilita.
    @Test func disableAndPracticeCoexist() async throws {
        let e = SkillEngine(queue: try AnimaDatabase.temporary(), directory: try SkillFixtures.standard())
        await e.practice("nota-diaria", outcome: .success)
        await e.setDisabled("nota-diaria", true)
        await e.practice("nota-diaria", outcome: .success)
        #expect(await e.isDisabled("nota-diaria"))
        #expect(await e.stats("nota-diaria")?.totalSuccess == 2)
    }

    @Test func overviewListsStateForSettings() async throws {
        let e = SkillEngine(queue: try AnimaDatabase.temporary(), directory: try SkillFixtures.standard())
        for _ in 0..<3 { await e.practice("agendar-con-contexto", outcome: .success) }
        await e.setDisabled("resumen-manana", true)
        let rows = await e.overview()
        #expect(rows.map(\.name) == ["agendar-con-contexto", "nota-diaria", "resumen-manana"])
        #expect(rows[0].practiced && rows[0].totalSuccess == 3 && rows[0].successStreak == 3)
        #expect(rows[0].summary.hasPrefix("Crea eventos"))
        #expect(!rows[1].practiced && rows[1].totalSuccess == 0 && !rows[1].disabled)
        #expect(rows[2].disabled)
        #expect(rows[2].summary.hasPrefix("resumen de mañana"))   // sin description ⇒ when
    }
}

// MARK: - SkillStore (hot-reload) y seed

@Suite struct SkillStoreTests {
    @Test func hotReloadsOnlyWhenMtimeChanges() throws {
        let dir = try SkillFixtures.dir(["nota.md": SkillFixtures.nota])
        let store = SkillStore(directory: dir)
        #expect(store.skills().map(\.name) == ["nota-diaria"])
        #expect(store.skills().count == 1)
        #expect(store.reloadCount == 1)   // la segunda lectura sale del caché

        // Edición: mismo tamaño no importa — la mtime cambia.
        let file = dir.appendingPathComponent("nota.md")
        try SkillFixtures.nota.replacingOccurrences(of: "nota-diaria", with: "nota-diarja")
            .write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                              ofItemAtPath: file.path)
        #expect(store.skills().map(\.name) == ["nota-diarja"])
        #expect(store.reloadCount == 2)

        // Alta de un skill nuevo con layout doc 05 (<x>/SKILL.md); drafts/ no carga.
        try SkillFixtures.agendar.write(to: dir.appendingPathComponent("agendar.md"), atomically: true, encoding: .utf8)
        let nested = dir.appendingPathComponent("resumen")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try SkillFixtures.resumen.write(to: nested.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let drafts = dir.appendingPathComponent("drafts")
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        try SkillFixtures.resumen.write(to: drafts.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "no es skill".write(to: dir.appendingPathComponent("leeme.txt"), atomically: true, encoding: .utf8)
        #expect(store.skills().map(\.name) == ["agendar-con-contexto", "nota-diarja", "resumen-manana"])
        #expect(store.reloadCount == 3)

        // Baja.
        try FileManager.default.removeItem(at: file)
        #expect(store.skills().map(\.name) == ["agendar-con-contexto", "resumen-manana"])
    }

    @Test func missingDirectoryIsEmpty() {
        let store = SkillStore(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(store.skills().isEmpty)
    }

    @Test func seedCopiesOnceIntoEmptyDir() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("skills")
        let copied = try SkillSeeder.seedIfEmpty(from: SkillFixtures.seedsDir, to: dest)
        #expect(copied == ["agendar-con-contexto.md", "nota-diaria.md"])
        #expect(SkillStore(directory: dest).skills().count == 2)
        // Idempotente: el segundo arranque no copia nada (ni pisa ediciones).
        #expect(try SkillSeeder.seedIfEmpty(from: SkillFixtures.seedsDir, to: dest).isEmpty)
    }

    @Test func seedSkipsWhenOwnerAlreadyHasSkills() throws {
        let dest = try SkillFixtures.dir(["mio.md": SkillFixtures.resumen])
        #expect(try SkillSeeder.seedIfEmpty(from: SkillFixtures.seedsDir, to: dest).isEmpty)
        #expect(SkillStore(directory: dest).skills().map(\.name) == ["resumen-manana"])
    }

    @Test func seedWithoutSourceOnlyCreatesDir() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(try SkillSeeder.seedIfEmpty(from: nil, to: dest).isEmpty)
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }
}
