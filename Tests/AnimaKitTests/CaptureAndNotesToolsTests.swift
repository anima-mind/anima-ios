import Foundation
import Testing
@testable import AnimaKit

#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

// MARK: - AudioTool

@Suite struct AudioToolTests {

    @Test func withoutInjectedRecorderTellsOwnerToStartFromApp() async {
        let r = await AudioTool().execute(.object([:]))
        #expect(!r.isError)
        #expect(r.content.contains("la inicia el dueño"))
    }

    @Test func transcriptIsPrefixedAndMaxSecondsClamped() async {
        let asked = Locked<[Int]>([])
        let tool = AudioTool(transcribe: { seconds in asked.mutate { $0.append(seconds) }; return "compra leche" })
        let r = await tool.execute(.object(["max_seconds": .int(900)]))
        #expect(r == ToolResult(content: "[transcrito de audio] compra leche"))
        _ = await tool.execute(.object(["max_seconds": .int(0)]))
        _ = await tool.execute(.object([:]))
        #expect(asked.value == [300, 1, 60])
    }

    @Test func emptyOrFailedTranscriptIsError() async {
        #expect(await AudioTool(transcribe: { _ in "" }).execute(.object([:])).isError)
        #expect(await AudioTool(transcribe: { _ in nil }).execute(.object([:])).isError)
    }

    @Test func contractForConfirmation() {
        let tool = AudioTool()
        #expect(tool.operation(for: .object([:])) == "record")
        #expect(tool.confirmationSummary(for: .object(["max_seconds": .int(30)]))
                == "Grabar y transcribir audio (hasta 30s, on-device)")
        #expect(AudioTool.transcriptBlock("hola") == .text("[transcrito de audio] hola"))
    }
}

// MARK: - CameraTool

@Suite struct CameraToolTests {

    #if canImport(CoreGraphics)
    private func png(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func capturedPhotoIsDownscaledAndDescribed() async {
        let data = png(width: 3136, height: 1000)
        let r = await CameraTool(capture: { data }).execute(.object([:]))
        #expect(!r.isError)
        #expect(r.content.hasPrefix("Foto capturada y adjuntada (1568×"))
        #expect(r.content.contains("image/jpeg"))
    }
    #endif

    @Test func captureFailuresAreReported() async {
        let none = await CameraTool(capture: { nil }).execute(.object([:]))
        #expect(none.isError && none.content.contains("No se capturó"))
        let garbage = await CameraTool(capture: { Data("no es imagen".utf8) }).execute(.object([:]))
        #expect(garbage.isError && garbage.content.contains("no pudo procesarse"))
    }

    @Test func withoutInjectedCaptureAndSummary() async {
        let r = await CameraTool().execute(.object([:]))
        #expect(!r.isError && r.content.contains("la inicia el dueño"))
        let tool = CameraTool()
        #expect(tool.operation(for: .object([:])) == "capture_photo")
        #expect(tool.confirmationSummary(for: .object(["reason": .string("ver la etiqueta")]))
                == "Tomar una foto con la cámara (ver la etiqueta)")
        #expect(tool.confirmationSummary(for: .object([:])) == "Tomar una foto con la cámara (sin motivo indicado)")
    }
}

// MARK: - NotesTool

@Suite struct NotesToolTests {

    private func withTool(_ body: (NotesTool, URL) async throws -> Void) async rethrows {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(NotesTool(root: root), root)
    }

    private func call(_ tool: NotesTool, _ pairs: [String: String]) async -> ToolResult {
        await tool.execute(.object(pairs.mapValues { .string($0) }))
    }

    @Test func createReadAppendListRoundTrip() async {
        await withTool { tool, _ in
            #expect(await call(tool, ["action": "list"]).content == "No hay notas todavía.")
            _ = await call(tool, ["action": "create", "name": "compras", "content": "leche"])
            #expect(await call(tool, ["action": "append", "name": "compras", "content": "pan"])
                    == ToolResult(content: "Anexado a 'compras'."))
            #expect(await call(tool, ["action": "read", "name": "compras"]).content == "leche\npan")
            _ = await call(tool, ["action": "append", "name": "ideas.md", "content": "primera"])
            #expect(await call(tool, ["action": "read", "name": "ideas.md"]).content == "primera")
            let list = await call(tool, ["action": "list"])
            #expect(list.content == "compras.txt\nideas.md")
        }
    }

    @Test func readMissingAndEmptyNotes() async {
        await withTool { tool, _ in
            let missing = await call(tool, ["action": "read", "name": "fantasma"])
            #expect(missing.isError && missing.content == "La nota 'fantasma' no existe.")
            _ = await call(tool, ["action": "create", "name": "vacia", "content": ""])
            #expect(await call(tool, ["action": "read", "name": "vacia"]).content == "(nota vacía)")
        }
    }

    @Test func traversalIsConfinedToSandbox() async {
        await withTool { tool, root in
            _ = await call(tool, ["action": "create", "name": "../../escape", "content": "x"])
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path))
            for bad in ["..", ".", "/", ""] {
                for action in ["read", "create", "append"] {
                    let r = await call(tool, ["action": action, "name": bad])
                    #expect(r.isError, "\(action) con name '\(bad)' debería fallar")
                }
            }
            #expect(await tool.execute(.object(["action": .string("read")])).isError)  // sin name
        }
    }

    @Test func missingAndUnknownActions() async {
        await withTool { tool, _ in
            #expect(await tool.execute(.object([:])).content == "Error: falta 'action'.")
            #expect(await call(tool, ["action": "delete"]).content == "Error: acción desconocida 'delete'.")
        }
    }

    @Test func fileSystemErrorsAreReported() async throws {
        // El sandbox apunta a un ARCHIVO: crear el directorio falla.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let r = await NotesTool(root: file).execute(.object(["action": .string("list")]))
        #expect(r.isError && r.content.hasPrefix("Error de sistema de archivos"))
    }

    @Test func appendFailureIsReported() async throws {
        try await withTool { tool, root in
            _ = await call(tool, ["action": "list"])  // crea el sandbox
            // Un directorio con el nombre de la nota impide escribirla.
            try FileManager.default.createDirectory(at: root.appendingPathComponent("bloqueada.txt"),
                                                    withIntermediateDirectories: true)
            let r = await call(tool, ["action": "append", "name": "bloqueada", "content": "x"])
            #expect(r.isError && r.content.hasPrefix("Error al anexar"))
        }
    }
}
