import Foundation
import Testing
import GRDB
@testable import AnimaKit

// Campo batch 3 / FIX A: crear skills es CONVERSACIONAL. Taller en sesión
// efímera (no toca el hilo principal ni el inbox del sueño), el córtex redacta
// dentro de <skill>…</skill>, "Guardar" escribe front-matter válido y matcheable;
// importar desde Archivos con y sin front-matter; editar/renombrar/eliminar.

enum WorkshopFixtures {
    static func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let draftReply = """
        Listo, así quedaría:
        <skill>
        ---
        name: regar-plantas
        description: Guía el riego de las plantas de la casa
        when: regar las plantas, riego, plantas de la casa
        ---
        1. Pregunta qué plantas toca regar hoy.
        2. El helecho va cada dos días.
        </skill>
        ¿Algo más o lo cambio?
        """

    static func selector(_ provider: Provider) throws -> ProviderSelector {
        .claudeOnly(provider: provider, router: ModelRouter(config: try TestConfig.providerConfig()),
                    authMode: .apiKey, token: "sk-ant-api03-x")
    }
}

@Suite("Campo — SkillMarkdown")
struct SkillMarkdownTests {
    @Test func extraeElUltimoBloqueYLoQuitaDelTextoVisible() {
        let text = "a <skill>viejo</skill> b " + WorkshopFixtures.draftReply
        let block = try? #require(SkillMarkdown.extractBlock(from: text))
        #expect(block?.hasPrefix("---\nname: regar-plantas") == true)
        let visible = SkillMarkdown.strippingBlocks(WorkshopFixtures.draftReply)
        #expect(visible.contains("Listo, así quedaría:"))
        #expect(visible.contains("¿Algo más o lo cambio?"))
        #expect(!visible.contains("name:"))
    }

    @Test func bloqueAbiertoDuranteElStreamingYFenceDeCodigo() {
        #expect(SkillMarkdown.extractBlock(from: "hola <skill>\n---\nname: x") == "---\nname: x")
        #expect(SkillMarkdown.strippingBlocks("hola <skill>\n---\nname: x") == "hola")
        let fenced = "<skill>\n```markdown\n---\nname: x\nwhen: y\n---\ncuerpo\n```\n</skill>"
        #expect(SkillMarkdown.extractBlock(from: fenced) == "---\nname: x\nwhen: y\n---\ncuerpo")
        #expect(SkillMarkdown.extractBlock(from: "sin bloque") == nil)
    }

    @Test func normalizaSinFrontMatterYSlug() throws {
        let wrapped = SkillMarkdown.normalized("1. Abre la app.\n2. Toma agua.", fallbackName: "Rutina de mañana")
        let skill = try #require(SkillEngine.parse(wrapped))
        #expect(skill.name == "rutina-de-manana")
        #expect(skill.when == "Rutina de mañana")
        #expect(skill.body.contains("Toma agua"))
        let valid = SkillMarkdown.compose(name: "x", when: "y", body: "z")
        #expect(SkillMarkdown.normalized(valid, fallbackName: "otro") == valid)
        #expect(SkillMarkdown.slug("¡Regar las Plantas!") == "regar-las-plantas")
    }
}

@Suite("Campo — SkillLibrary (crear/importar/editar/eliminar)")
struct SkillLibraryTests {
    @Test func creadorEscribeFrontMatterValidoYElEngineLaMatchea() async throws {
        let dir = try WorkshopFixtures.directory()
        let library = SkillLibrary(directory: dir)
        let draft = try #require(SkillMarkdown.extractBlock(from: WorkshopFixtures.draftReply))
        try library.save(draft)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("regar-plantas.md").path))
        let engine = SkillEngine(queue: try AnimaDatabase.temporary(), directory: dir)
        #expect(await engine.bestMatch("recuérdame regar las plantas")?.skill.name == "regar-plantas")
    }

    @Test func importConYSinFrontMatter() throws {
        let dir = try WorkshopFixtures.directory()
        let library = SkillLibrary(directory: dir)
        let src = try WorkshopFixtures.directory()
        let withFM = src.appendingPathComponent("cualquiera.md")
        try SkillMarkdown.compose(name: "cierre-semana", when: "cierre de semana", body: "1. Revisa.")
            .write(to: withFM, atomically: true, encoding: .utf8)
        #expect(try library.importFile(withFM).name == "cierre-semana")

        let plain = src.appendingPathComponent("Lista de compras.txt")
        try "1. Leche\n2. Pan".write(to: plain, atomically: true, encoding: .utf8)
        let imported = try library.importFile(plain)
        #expect(imported.name == "lista-de-compras")
        #expect(imported.body.contains("Leche"))

        #expect(throws: (any Error).self) { try library.importFile(src.appendingPathComponent("noexiste.md")) }
    }

    @Test func editarReescribeSinRomperLaPracticaYRenombrarEsSkillNueva() async throws {
        let dir = try WorkshopFixtures.directory()
        let library = SkillLibrary(directory: dir)
        let queue = try AnimaDatabase.temporary()
        let engine = SkillEngine(queue: queue, directory: dir)
        try library.save(SkillMarkdown.compose(name: "nota", when: "nota diaria", body: "1. Anota."))
        await engine.practice("nota", success: true)
        await engine.practice("nota", success: true)

        // Mismo nombre: sobrescribe el MISMO archivo; la práctica (por nombre) sigue.
        try library.save(SkillMarkdown.compose(name: "nota", when: "nota diaria, bitácora", body: "1. Anota breve."),
                         replacing: "nota")
        #expect(SkillStore.skillFiles(in: dir).count == 1)
        #expect(await engine.stats("nota")?.totalSuccess == 2)
        #expect(await engine.loadSkills().first?.when == "nota diaria, bitácora")

        // Renombrar: archivo nuevo, el viejo se va, la práctica NO migra.
        try library.save(SkillMarkdown.compose(name: "bitacora", when: "bitácora", body: "1. Anota."),
                         replacing: "nota")
        #expect(library.file(named: "nota") == nil)
        #expect(library.file(named: "bitacora") != nil)
        #expect(await engine.stats("bitacora") == nil)

        try library.delete(named: "bitacora")
        #expect(await engine.loadSkills().isEmpty)
        #expect(throws: SkillLibrary.LibraryError.invalid) { try library.save("sin front-matter") }
    }

    @Test func nombresRepetidosNoPisanOtroArchivo() throws {
        let dir = try WorkshopFixtures.directory()
        let library = SkillLibrary(directory: dir)
        try "---\nname: a\nwhen: x\n---\n".write(to: dir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try library.save(SkillMarkdown.compose(name: "b", when: "y", body: ""))
        #expect(SkillStore.skillFiles(in: dir).map(\.lastPathComponent) == ["b-2.md", "b.md"])
    }
}

@Suite("Campo — taller de skills en sesión efímera")
struct SkillWorkshopSessionTests {
    @Test func laSesionEfimeraNoTocaElStorePrincipalNiElInbox() async throws {
        let mainQueue = try AnimaDatabase.temporary()
        let inbox = ConsolidationInbox(queue: mainQueue)
        let provider = CapturingProvider([.text(WorkshopFixtures.draftReply)])
        let session = try SkillWorkshopSession.make(selector: try WorkshopFixtures.selector(provider),
                                                    telemetry: Telemetry(queue: mainQueue),
                                                    selfModel: SelfModel(queue: mainQueue), mode: .create)
        var text = ""
        for await event in await session.loop.run(sessionId: session.sessionId, content: [.text("Regar las plantas")]) {
            if case .textDelta(let d) = event { text += d }
        }
        #expect(text.contains("<skill>"))
        let (sessions, turns) = try await mainQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM turn_event") ?? -1)
        }
        #expect(sessions == 0)
        #expect(turns == 0)
        #expect(try inbox.pendingCount() == 0)
        // El system de tarea llegó al córtex; sin tools.
        let capture = try #require(provider.captures.value.first)
        #expect(capture.messages.contains { $0.role == .system && $0.content.contains { block in
            if case .text(let t) = block { return t.contains(SkillWorkshopSession.marker) } else { return false }
        } })
    }

    @Test func instruccionesDeEditarLlevanLaSkillActual() {
        let text = SkillWorkshopSession.instructions(for: .edit(name: "nota", markdown: "---\nname: nota\n---"))
        #expect(text.contains("name: nota"))
        #expect(text.contains("renombrarla reinicia su práctica"))
        #expect(!SkillWorkshopSession.instructions(for: .create).contains("tal como está hoy"))
    }
}

#if canImport(SwiftUI)
@MainActor
@Suite("Campo — SkillWorkshopViewModel")
struct SkillWorkshopViewModelTests {
    static func model(_ mode: SkillWorkshopMode, dir: URL, replies: [String], practice: Int = 0)
        throws -> SkillWorkshopViewModel {
        let queue = try AnimaDatabase.temporary()
        let selector = try WorkshopFixtures.selector(ScriptedProvider(replies.map { [ProviderEvent].text($0) }))
        return SkillWorkshopViewModel(mode: mode, library: SkillLibrary(directory: dir), practiceSuccesses: practice,
                                      makeSession: { mode in
            try SkillWorkshopSession.make(selector: selector, telemetry: Telemetry(queue: queue),
                                          selfModel: nil, mode: mode)
        })
    }

    @Test func crearConversandoYGuardar() async throws {
        let dir = try WorkshopFixtures.directory()
        let model = try Self.model(.create, dir: dir, replies: [WorkshopFixtures.draftReply])
        await model.start(animated: false)
        #expect(model.messages.first?.text == SkillWorkshopViewModel.openingCreate)
        #expect(!model.chips.isEmpty)
        #expect(!model.canSave)
        model.input = "Regar las plantas"
        await model.send()
        #expect(model.draftSkill?.name == "regar-plantas")
        #expect(model.messages.last?.text.contains("¿Algo más o lo cambio?") == true)
        #expect(model.messages.last?.text.contains("name:") == false)
        #expect(model.canSave)
        #expect(model.chips.contains("Así está bien"))
        var changed = 0
        model.onChanged = { changed += 1 }
        #expect(model.save())
        #expect(model.saved)
        #expect(changed == 1)
        #expect(SkillLibrary(directory: dir).file(named: "regar-plantas") != nil)
    }

    @Test func sinCortexAvisaSinRomper() async throws {
        let dir = try WorkshopFixtures.directory()
        let model = SkillWorkshopViewModel(mode: .create, library: SkillLibrary(directory: dir), makeSession: nil)
        await model.send("hola")
        #expect(model.messages.last?.isError == true)
        #expect(model.messages.last?.text == SkillWorkshopViewModel.noCortex)
    }

    @Test func editarCargaLaSkillYAvisaAlRenombrar() async throws {
        let dir = try WorkshopFixtures.directory()
        let library = SkillLibrary(directory: dir)
        let original = SkillMarkdown.compose(name: "plantas", when: "plantas", body: "1. Riega.")
        try library.save(original)
        let model = try Self.model(.edit(name: "plantas", markdown: original), dir: dir,
                                   replies: [WorkshopFixtures.draftReply], practice: 4)
        await model.start(animated: false)
        #expect(model.messages.first?.text == SkillWorkshopViewModel.openingEdit)
        #expect(model.draftSkill?.name == "plantas")
        #expect(model.renameWarning == nil)
        await model.send("cámbiale el nombre a regar-plantas")
        #expect(model.renameWarning?.contains("4 éxitos") == true)
        #expect(model.save())
        #expect(library.file(named: "plantas") == nil)
        #expect(library.file(named: "regar-plantas") != nil)
    }

    @Test func eliminarConConfirmacionBorraElArchivo() async throws {
        let dir = try WorkshopFixtures.directory()
        let library = SkillLibrary(directory: dir)
        let md = SkillMarkdown.compose(name: "nota-diaria", when: "nota", body: "")
        try library.save(md)
        let model = try Self.model(.edit(name: "nota-diaria", markdown: md), dir: dir, replies: [])
        model.delete()
        #expect(model.saved)
        #expect(library.file(named: "nota-diaria") == nil)
    }

    @Test func skillsViewModelResumenImportYTaller() async throws {
        let dir = try WorkshopFixtures.directory()
        let engine = SkillEngine(queue: try AnimaDatabase.temporary(), directory: dir)
        let skills = SkillsViewModel(engine: engine, library: SkillLibrary(directory: dir))
        await skills.reload()
        #expect(skills.summaryLine == "Sin skills todavía")
        #expect(!skills.canTeach)
        #expect(skills.workshop() != nil)   // crear existe aunque falte córtex (avisa al enviar)
        let file = try WorkshopFixtures.directory().appendingPathComponent("rutina.txt")
        try "1. Estira.".write(to: file, atomically: true, encoding: .utf8)
        await skills.importFile(file)
        #expect(skills.notice == "Importada: rutina.")
        #expect(skills.summaryLine == "1 aprendida · 0 automatizadas")
        #expect(skills.workshop(editing: "rutina")?.isEditing == true)
        #expect(skills.workshop(editing: "no-existe") == nil)
    }
}
#endif
