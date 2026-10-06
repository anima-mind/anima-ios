import Foundation
import Testing
@testable import AnimaKit

// Campo #4 (negrilla con asteriscos) y batch 5b #2 ("los ### no hacen nada y esa
// tabla horrible"): parser de BLOQUES determinista.

@Suite("Campo — markdown del chat (ChatMarkdown)")
struct ChatMarkdownTests {
    typealias B = ChatMarkdown.Block

    static func plain(_ a: AttributedString) -> String { String(a.characters) }

    static func paragraph(_ block: B?) -> AttributedString? {
        if case .paragraph(let a)? = block { return a } else { return nil }
    }

    /// El mensaje real de la captura del dueño.
    static let planMensual = """
        ## 📅 Plan mensual de ahorro

        Para llegar a **10 millones** en un año:

        | Mes | Aporte | Acumulado |
        |-----|-------:|----------:|
        | Octubre | $850.000 | $850.000 |
        | Noviembre | $850.000 | $1.700.000 |
        | Diciembre | $1.000.000 | $2.700.000 |

        ### Para aterrizarlo…
        - Programa una **transferencia automática** el día 1.
        - Revisa gastos hormiga:
          - domicilios
          - suscripciones
        1. Abre el CDT en noviembre.
        2. Revisa el avance cada mes.

        > Lo que no se mide no se mejora.

        ---
        ¿Te lo dejo como recordatorio?
        """

    @Test func elPlanMensualSeVuelveBloques() throws {
        let blocks = ChatMarkdown.blocks(Self.planMensual)
        guard blocks.count == 9 else { Issue.record("bloques: \(blocks)"); return }
        #expect(blocks[0] == .heading(level: 2, ChatMarkdown.inline("📅 Plan mensual de ahorro")))
        #expect(Self.paragraph(blocks[1]).map(Self.plain) == "Para llegar a 10 millones en un año:")
        guard case .table(let table) = blocks[2] else { Issue.record("no es tabla: \(blocks[2])"); return }
        #expect(table.header.map(Self.plain) == ["Mes", "Aporte", "Acumulado"])
        #expect(table.rows.count == 3)
        #expect(table.rows[2].map(Self.plain) == ["Diciembre", "$1.000.000", "$2.700.000"])
        #expect(table.alignments == [.leading, .trailing, .trailing])
        #expect(table.columnCount == 3)
        #expect(blocks[3] == .heading(level: 3, ChatMarkdown.inline("Para aterrizarlo…")))
        guard case .list(false, let bullets) = blocks[4] else { Issue.record("no es lista: \(blocks[4])"); return }
        #expect(bullets.count == 2)
        #expect(bullets[0].marker == "•")
        #expect(Self.plain(bullets[0].text) == "Programa una transferencia automática el día 1.")
        let bold = try #require(bullets[0].text.range(of: "transferencia automática"))
        #expect(bullets[0].text[bold].inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        #expect(bullets[1].children.map { Self.plain($0.text) } == ["domicilios", "suscripciones"])
        guard case .list(true, let numbered) = blocks[5] else { Issue.record("no es numerada: \(blocks[5])"); return }
        #expect(numbered.map(\.marker) == ["1.", "2."])
        #expect(blocks[6] == .quote(ChatMarkdown.inline("Lo que no se mide no se mejora.")))
        #expect(blocks[7] == .rule)
        #expect(Self.paragraph(blocks[8]).map(Self.plain) == "¿Te lo dejo como recordatorio?")
    }

    @Test func encabezadosSinNumeralesYNoConfundeHashtags() {
        #expect(ChatMarkdown.blocks("# Uno\n## Dos ##\n###### Seis") == [
            .heading(level: 1, ChatMarkdown.inline("Uno")),
            .heading(level: 2, ChatMarkdown.inline("Dos")),
            .heading(level: 6, ChatMarkdown.inline("Seis")),
        ])
        #expect(Self.paragraph(ChatMarkdown.blocks("#hashtag").first).map(Self.plain) == "#hashtag")
        #expect(Self.paragraph(ChatMarkdown.blocks("####### siete").first).map(Self.plain) == "####### siete")
    }

    @Test func encabezadoPegadoSinEspacio() {
        #expect(ChatMarkdown.blocks("##Plan de ahorro\n###Ñandú") == [
            .heading(level: 2, ChatMarkdown.inline("Plan de ahorro")),
            .heading(level: 3, ChatMarkdown.inline("Ñandú")),
        ])
        #expect(Self.paragraph(ChatMarkdown.blocks("##1 de 3").first).map(Self.plain) == "##1 de 3")
        #expect(Self.paragraph(ChatMarkdown.blocks("##").first) == nil)
        #expect(Self.paragraph(ChatMarkdown.blocks("#Colombia").first).map(Self.plain) == "#Colombia")
    }

    @Test func negrillaCursivaYCodigoInline() throws {
        let blocks = ChatMarkdown.blocks("Tienes **dos** reuniones y *hoy* `cron` pendiente.")
        #expect(blocks.count == 1)
        let a = try #require(Self.paragraph(blocks.first))
        #expect(Self.plain(a) == "Tienes dos reuniones y hoy cron pendiente.")
        let italic = try #require(a.range(of: "hoy"))
        #expect(a[italic].inlinePresentationIntent?.contains(.emphasized) == true)
        let code = try #require(a.range(of: "cron"))
        #expect(a[code].inlinePresentationIntent?.contains(.code) == true)
    }

    @Test func linksYSaltosDeLineaSeConservan() throws {
        let a = try #require(Self.paragraph(ChatMarkdown.blocks("Mira [esto](https://anima.dev)\nsegunda línea").first))
        #expect(Self.plain(a) == "Mira esto\nsegunda línea")
        let link = try #require(a.range(of: "esto"))
        #expect(a[link].link == URL(string: "https://anima.dev"))
    }

    @Test func bloqueFencedVaAparte() throws {
        let blocks = ChatMarkdown.blocks("Ejecuta esto:\n```bash\nswift test\nswift build\n```\nY listo.")
        #expect(blocks.count == 3)
        #expect(Self.paragraph(blocks[0]).map(Self.plain) == "Ejecuta esto:")
        #expect(blocks[1] == .code("swift test\nswift build", language: "bash"))
        #expect(Self.paragraph(blocks[2]).map(Self.plain) == "Y listo.")
        #expect(ChatMarkdown.blocks("```\nx\n```") == [.code("x", language: nil)])
        // Dentro del código nada es markdown.
        #expect(ChatMarkdown.blocks("```\n# no\n| a | b |\n|---|---|\n```") == [.code("# no\n| a | b |\n|---|---|", language: nil)])
    }

    @Test func tablasRarasYEscapes() throws {
        let blocks = ChatMarkdown.blocks("a | b\n:-:|---\nx \\| y | z\n\ndespués")
        guard case .table(let t) = blocks.first else { Issue.record("\(blocks)"); return }
        #expect(t.header.map(Self.plain) == ["a", "b"])
        #expect(t.alignments == [.center, .leading])
        #expect(t.rows.first.map { $0.map(Self.plain) } == ["x | y", "z"])
        #expect(Self.paragraph(blocks.last).map(Self.plain) == "después")
        // Filas con menos celdas: el ancho lo fija la más larga.
        let ragged = ChatMarkdown.blocks("| a |\n|---|\n| 1 | 2 | 3 |")
        guard case .table(let r) = ragged.first else { Issue.record("\(ragged)"); return }
        #expect(r.columnCount == 3)
        // Separador inválido: no es tabla.
        #expect(Self.paragraph(ChatMarkdown.blocks("| a | b |\n| x | y |").first) != nil)
        #expect(ChatMarkdown.separatorAlignments("|---|abc|") == nil)
        #expect(ChatMarkdown.separatorAlignments("texto") == nil)
    }

    @Test func listasContinuacionYCambioDeTipo() throws {
        let blocks = ChatMarkdown.blocks("* uno\n  sigue\n+ dos\n  - hijo\n    más del hijo\n3) tres")
        guard blocks.count == 2, case .list(false, let items) = blocks[0], case .list(true, let ordered) = blocks[1] else {
            Issue.record("\(blocks)"); return
        }
        #expect(items.map { Self.plain($0.text) } == ["uno\nsigue", "dos"])
        #expect(items[1].children.map { Self.plain($0.text) } == ["hijo\nmás del hijo"])
        #expect(ordered.map(\.marker) == ["3."])
        #expect(ChatMarkdown.listItem("-sin espacio") == nil)
        #expect(ChatMarkdown.listItem("1234. demasiados dígitos") == nil)
        #expect(ChatMarkdown.listItem("\t- tab")?.indent == 4)
    }

    @Test func separadoresYCitas() {
        #expect(ChatMarkdown.blocks("***") == [.rule])
        #expect(ChatMarkdown.blocks("_ _ _") == [.rule])
        #expect(Self.paragraph(ChatMarkdown.blocks("--").first) != nil)
        #expect(ChatMarkdown.blocks(">uno\n> dos") == [.quote(ChatMarkdown.inline("uno\ndos"))])
        #expect(ChatMarkdown.blocks("> cita\ntexto").count == 2)
    }

    @Test func streamingNuncaRompeYLoCerradoSeMantiene() throws {
        // Negrilla sin cerrar: texto plano (con sus asteriscos), sin crash.
        let open = try #require(Self.paragraph(ChatMarkdown.blocks("Tienes **dos reun").first))
        #expect(Self.plain(open) == "Tienes **dos reun")
        // Fence abierto: ya es código (no parpadea al cerrarse).
        #expect(ChatMarkdown.blocks("Corre:\n```swift\nlet x = 1").last == .code("let x = 1", language: "swift"))
        // Tabla sin separador aún: texto; con separador y fila a medias: tabla con lo que hay.
        #expect(Self.paragraph(ChatMarkdown.blocks("| Mes | Aporte |").first) != nil)
        let partial = ChatMarkdown.blocks("| Mes | Aporte |\n|---|---|\n| Octubre | $8")
        guard case .table(let t)? = partial.first else { Issue.record("\(partial)"); return }
        #expect(t.rows.first.map { $0.map(Self.plain) } == ["Octubre", "$8"])
        // Cada prefijo del mensaje real parsea sin romper, y el encabezado no cambia de tipo.
        let full = Self.planMensual
        var sawHeading = false
        for i in 0...full.count {
            let blocks = ChatMarkdown.blocks(String(full.prefix(i)))
            if case .heading? = blocks.first { sawHeading = true }
            if sawHeading, i > 20 {
                guard case .heading? = blocks.first else { Issue.record("el título parpadeó en \(i)"); return }
            }
        }
        #expect(ChatMarkdown.blocks("").isEmpty)
        #expect(ChatMarkdown.blocks("\n  \n").isEmpty)
        #expect(Self.plain(ChatMarkdown.inline("a < b & c")) == "a < b & c")
    }
}
