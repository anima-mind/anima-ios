import Foundation
import Testing
@testable import AnimaKit

// Campo #11: la cámara del composer mostraba "Disponible pronto". Cámara o
// galería → ImageDownscaler → thumb en el composer → turno multimodal.

@Suite("Campo — foto desde el composer del teléfono")
@MainActor
struct PhonePhotoTests {

    static func chat(_ provider: CapturingProvider) throws -> ChatViewModel {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [], serverTools: [], sleep: { _ in })
        return ChatViewModel(loop: loop, sessionId: try store.startSession())
    }

    @Test func fotoReducidaMasTextoVaComoTurnoMultimodal() async throws {
        let provider = CapturingProvider([.text("Es una pared azul.")])
        let chat = try Self.chat(provider)
        #expect(chat.attachPhoto(makeJPEG()))   // 2000×1000 → ≤1568
        let pending = try #require(chat.pendingImage)
        guard case .image(let media, _) = pending.block else { Issue.record("sin image block"); return }
        #expect(media == "image/jpeg")
        #expect(!pending.thumb.isEmpty)

        chat.input = "¿qué es esto?"
        await chat.send()
        #expect(chat.pendingImage == nil)
        let sent = try #require(provider.captures.value.first?.messages.last { $0.role == .user })
        #expect(sent.content.count == 2)
        #expect(sent.content.first == pending.block)
        #expect(sent.content.last == .text("¿qué es esto?"))
        // La burbuja del dueño lleva el thumb.
        #expect(chat.messages.first?.imageData == pending.thumb)
        #expect(chat.messages.first?.text == "¿qué es esto?")
    }

    @Test func quitarElThumbMandaSoloTextoYSoloFotoTambienSirve() async throws {
        let provider = CapturingProvider([.text("ok"), .text("veo")])
        let chat = try Self.chat(provider)
        chat.attachPhoto(makeJPEG(width: 400, height: 300))
        chat.removePhoto()
        chat.input = "solo texto"
        await chat.send()
        let first = try #require(provider.captures.value.first?.messages.last { $0.role == .user })
        #expect(first.content == [.text("solo texto")])

        // Sin texto: la foto sola también es un turno.
        chat.attachPhoto(makeJPEG(width: 400, height: 300))
        await chat.send()
        let second = try #require(provider.captures.value.last?.messages.last { $0.role == .user })
        #expect(second.content.count == 1)
        if case .image = second.content.first {} else { Issue.record("sin imagen") }
    }

    @Test func soloTelefonoNoAdjuntaYNoEsImagenSeRechaza() throws {
        let chat = try Self.chat(CapturingProvider([]))
        #expect(chat.attachPhoto(Data([1, 2, 3])) == false)   // no es imagen
        chat.photosAvailable = false                         // modo onDeviceOnly
        #expect(chat.attachPhoto(makeJPEG()) == false)
        #expect(chat.pendingImage == nil)
        #expect(chat.attach(.text("x")) == false)
        #expect(ChatViewModel.photosNeedRemoteNote.contains("modelo remoto"))
    }

    @Test func historialConFotoMuestraElThumb() {
        let messages = ChatViewModel.history(current: [VisibleTurn(role: .user, text: "mira", imageBase64: "QUJD")])
        #expect(messages.first?.imageData == Data("ABC".utf8))
    }
}
