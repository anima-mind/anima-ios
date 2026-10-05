import Foundation
import Testing
import CoreGraphics
@testable import AnimaKit

// Campo batch 3 / FIX G: fotos del chat — decode async (jamás en el main),
// thumbnails acotados para las celdas, y Solo-teléfono avisa en vez de mandar
// la foto en silencio.

@Suite("Campo — ImageLoader")
struct ImageLoaderTests {
    @Test func downsamplingAcotaElLadoMayor() throws {
        let data = makeJPEG(width: 2000, height: 1000)
        let thumb = try #require(ImageLoader.thumbnail(data, maxPixel: 480))
        #expect(max(thumb.width, thumb.height) <= 480)
        #expect(thumb.width == 480)
        let full = try #require(ImageLoader.full(data))
        #expect(full.width == 2000 && full.height == 1000)
        #expect(ImageLoader.thumbnail(Data("no es imagen".utf8), maxPixel: 100) == nil)
        #expect(ImageLoader.full(Data()) == nil)
    }

    @MainActor
    @Test func elDecodeAsyncNoCorreEnElMain() async throws {
        let data = makeJPEG(width: 1200, height: 900)
        let onMain = Locked<Bool?>(nil)
        let image = await ImageLoader.load(data, maxPixel: 300, onDecode: { main in onMain.mutate { $0 = main } })
        #expect(image != nil)
        #expect(onMain.value == false)
        // Segunda carga: sale de caché, sin decodificar de nuevo.
        let again = Locked<Bool?>(nil)
        #expect(await ImageLoader.load(data, maxPixel: 300, onDecode: { m in again.mutate { $0 = m } }) != nil)
        #expect(again.value == nil)
        #expect(await ImageLoader.load(data, maxPixel: nil)?.width == 1200)
        #expect(await ImageLoader.load(Data([0, 1, 2]), maxPixel: 100) == nil)
    }
}

@Suite("Campo — foto en Solo-teléfono")
struct PhotoAsTextTests {
    @Test func bloqueDeTextoHonesto() async {
        #expect(ImageDescriber.textBlock(labels: []).contains("no puede verla"))
        let block = ImageDescriber.textBlock(labels: ["dog", "grass"])
        #expect(block.contains("dog, grass"))
        #expect(block.contains("no puede ver"))
        // Vision corre sin romper (una imagen plana puede no tener etiquetas).
        let labels = await ImageDescriber.labels(for: makeJPEG(width: 400, height: 300))
        #expect(labels.count <= 6)
        #expect(await ImageDescriber.labels(for: Data()) == [])
    }

    #if canImport(SwiftUI)
    @MainActor
    @Test func enviarEnSoloTelefonoMandaDescripcionYLoMarca() async throws {
        let provider = CapturingProvider([.text("Veo la descripción.")])
        let chat = try PhonePhotoTests.chat(provider)
        #expect(chat.inputPlaceholder == "Mensaje")
        #expect(chat.attachPhoto(makeJPEG()))
        #expect(chat.inputPlaceholder == "Agrega un mensaje…")
        #expect(chat.pendingImageNotice == nil)
        // El modo cambió a Solo-teléfono con la foto ya adjunta.
        chat.photosAvailable = false
        #expect(chat.pendingImageNotice == ImageDescriber.notice)
        chat.describeImage = { _ in ["plant"] }
        chat.input = "¿qué planta es?"
        await chat.send()

        let user = try #require(chat.messages.first { $0.role == .user })
        #expect(user.imageData != nil)
        #expect(user.photoSentAsText)
        let sent = try #require(provider.captures.value.first?.messages.last { $0.role == .user })
        #expect(!sent.content.contains { if case .image = $0 { return true } else { return false } })
        #expect(sent.content.contains { block in
            if case .text(let t) = block { return t.contains("plant") } else { return false }
        })
        #expect(chat.pendingImage == nil)
    }
    #endif
}
