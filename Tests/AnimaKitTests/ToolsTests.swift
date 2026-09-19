import Foundation
import Testing
@testable import AnimaKit

#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

@Suite struct ToolSchemaTests {

    /// Las 7 tools de §5.7 (6 client + web_search server), en orden alfabético
    /// estable y con schemas válidos.
    @Test func sevenToolsSortedAlphabetically() async {
        let clientTools: [any SensorimotorTool] = [
            CalendarTool(), RemindersTool(), NotesTool(), PhoneContextTool(), CameraTool(), AudioTool(),
        ]
        let sensorimotor = Sensorimotor(tools: clientTools)
        let allSpecs = await sensorimotor.toolSpecs() + [WebSearchTool.spec]
        let sorted = allSpecs.sorted { $0.name < $1.name }
        let names = sorted.map(\.name)
        #expect(names == ["audio", "calendar", "camera", "notes", "phone_context", "reminders", "web_search"])
    }

    /// Cada tool client-side declara un input_schema con "type":"object".
    @Test func clientSchemasAreValidObjects() {
        let clientTools: [any SensorimotorTool] = [
            CalendarTool(), RemindersTool(), NotesTool(), PhoneContextTool(), CameraTool(), AudioTool(),
        ]
        for tool in clientTools {
            guard case .client(_, let description, let schema) = tool.spec else {
                Issue.record("\(tool.spec.name) debería ser client-side")
                continue
            }
            #expect(!description.isEmpty)
            #expect(schema["type"] == .string("object"))
            #expect(schema["properties"]?.objectValue != nil)
        }
    }

    /// Clasificación de operación: leer = aferente, escribir = eferente (borrar
    /// siempre eferente). Camera/audio fuerzan eferente (regla de captura).
    @Test func operationKindsClassifiedCorrectly() {
        let calendar = CalendarTool()
        #expect(calendar.kind(for: .object(["action": .string("list")])) == .afferent)
        #expect(calendar.kind(for: .object(["action": .string("create")])) == .efferent)
        #expect(calendar.kind(for: .object(["action": .string("delete")])) == .efferent)

        let phone = PhoneContextTool()
        #expect(phone.kind(for: .object(["action": .string("location")])) == .afferent)

        #expect(CameraTool().kind(for: .object([:])) == .efferent)
        #expect(AudioTool().kind(for: .object([:])) == .efferent)
    }
}

@Suite struct ImageDownscalerTests {

    #if canImport(CoreGraphics)
    private func makePNG(width: Int, height: Int) -> Data {
        let bytesPerRow = width * 4
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Downscale al lado largo ≤1568px y media_type image/jpeg (fixture 2400×1200).
    @Test func downscalesToMaxLongSideAsJPEG() throws {
        let png = makePNG(width: 2400, height: 1200)
        let output = try #require(ImageDownscaler.process(png))
        #expect(output.mediaType == "image/jpeg")
        #expect(output.pixelWidth <= ImageDownscaler.maxLongSide)
        #expect(output.pixelHeight <= ImageDownscaler.maxLongSide)
        #expect(max(output.pixelWidth, output.pixelHeight) == ImageDownscaler.maxLongSide)

        // El image block sale con el media_type correcto y base64 no vacío.
        let block = try #require(ImageDownscaler.imageBlock(from: png))
        if case .image(let mediaType, let base64) = block {
            #expect(mediaType == "image/jpeg")
            #expect(!base64.isEmpty)
        } else {
            Issue.record("esperaba un image block")
        }
    }

    /// Una imagen ya pequeña no se agranda.
    @Test func smallImageNotUpscaled() throws {
        let png = makePNG(width: 800, height: 600)
        let output = try #require(ImageDownscaler.process(png))
        #expect(output.pixelWidth <= 800)
        #expect(output.pixelHeight <= 600)
    }
    #endif
}

@Suite struct LoopDetectorTests {

    /// Misma tool + mismo input 3 veces seguidas → detiene en la 3ª.
    @Test func stopsOnThirdIdenticalCall() {
        var detector = LoopDetector(threshold: 3)
        let input = JSONValue.object(["action": .string("list")])
        #expect(detector.record(tool: "calendar", input: input) == false)
        #expect(detector.record(tool: "calendar", input: input) == false)
        #expect(detector.record(tool: "calendar", input: input) == true)
    }

    /// Un input distinto reinicia la racha.
    @Test func differentInputResetsStreak() {
        var detector = LoopDetector(threshold: 3)
        let a = JSONValue.object(["q": .string("uno")])
        let b = JSONValue.object(["q": .string("dos")])
        _ = detector.record(tool: "web_search", input: a)
        _ = detector.record(tool: "web_search", input: a)
        #expect(detector.record(tool: "web_search", input: b) == false)  // reset
        #expect(detector.record(tool: "web_search", input: b) == false)
        #expect(detector.record(tool: "web_search", input: b) == true)
    }

    /// El orden de claves del input no altera la detección (canonicalización).
    @Test func keyOrderDoesNotMatter() {
        var detector = LoopDetector(threshold: 2)
        let a = JSONValue.object(["x": .int(1), "y": .int(2)])
        let b = JSONValue.object(["y": .int(2), "x": .int(1)])
        _ = detector.record(tool: "t", input: a)
        #expect(detector.record(tool: "t", input: b) == true)
    }
}
