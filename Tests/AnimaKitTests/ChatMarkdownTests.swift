import Foundation
import Testing
@testable import AnimaKit

// Campo #4: el markdown del chat no renderizaba (negrilla con asteriscos).

@Suite("Campo — markdown del chat (ChatMarkdown)")
struct ChatMarkdownTests {

    static func text(_ segment: ChatMarkdown.Segment?) -> AttributedString? {
        if case .text(let a)? = segment { return a } else { return nil }
    }

    @Test func negrillaCursivaYCodigoInline() throws {
        let segments = ChatMarkdown.segments("Tienes **dos** reuniones y *hoy* `cron` pendiente.")
        #expect(segments.count == 1)
        let a = try #require(Self.text(segments.first))
        #expect(String(a.characters) == "Tienes dos reuniones y hoy cron pendiente.")
        let bold = try #require(a.range(of: "dos"))
        #expect(a[bold].inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        let italic = try #require(a.range(of: "hoy"))
        #expect(a[italic].inlinePresentationIntent?.contains(.emphasized) == true)
        let code = try #require(a.range(of: "cron"))
        #expect(a[code].inlinePresentationIntent?.contains(.code) == true)
    }

    @Test func linksYSaltosDeLineaSeConservan() throws {
        let a = try #require(Self.text(ChatMarkdown.segments("Mira [esto](https://anima.dev)\nsegunda línea").first))
        #expect(String(a.characters) == "Mira esto\nsegunda línea")
        let link = try #require(a.range(of: "esto"))
        #expect(a[link].link == URL(string: "https://anima.dev"))
    }

    @Test func bloqueFencedVaAparte() throws {
        let source = "Ejecuta esto:\n```bash\nswift test\nswift build\n```\nY listo."
        let segments = ChatMarkdown.segments(source)
        #expect(segments.count == 3)
        #expect(Self.text(segments[0]).map { String($0.characters) } == "Ejecuta esto:")
        #expect(segments[1] == .code("swift test\nswift build", language: "bash"))
        #expect(Self.text(segments[2]).map { String($0.characters) } == "Y listo.")
        #expect(ChatMarkdown.segments("```\nx\n```") == [.code("x", language: nil)])
    }

    @Test func markdownRotoAMedioStreamDegradaSinCrash() throws {
        // Negrilla sin cerrar: texto plano (con sus asteriscos), sin crash.
        let open = try #require(Self.text(ChatMarkdown.segments("Tienes **dos reun").first))
        #expect(String(open.characters) == "Tienes **dos reun")
        // Fence abierto: ya es código (no parpadea al cerrarse).
        let streaming = ChatMarkdown.segments("Corre:\n```swift\nlet x = 1")
        #expect(streaming.last == .code("let x = 1", language: "swift"))
        // Cada prefijo del stream parsea sin romper.
        let full = "Hola **mundo** con `code` y [link](https://a.b)\n```\nfin\n```\n_ok_"
        for i in 0...full.count {
            _ = ChatMarkdown.segments(String(full.prefix(i)))
        }
        #expect(ChatMarkdown.segments("").isEmpty)
        #expect(ChatMarkdown.segments("\n  \n").isEmpty)
        #expect(String(ChatMarkdown.inline("a < b & c").characters) == "a < b & c")
    }
}
