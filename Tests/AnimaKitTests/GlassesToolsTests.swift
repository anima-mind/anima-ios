import Foundation
import Testing
@testable import AnimaKit

/// Host de tools configurable (sin HUD real).
final class MockToolHost: GlassesToolHost, @unchecked Sendable {
    let active = Locked(true)
    let projected = Locked<[HUDFlexBox]>([])
    let accept = Locked(true)
    let photo = Locked<Result<Data, Error>>(.success(Data()))
    func glassesActive() async -> Bool { active.value }
    func project(_ card: HUDFlexBox) async -> Bool {
        guard accept.value else { return false }
        projected.mutate { $0.append(card) }
        return true
    }
    func capturePOV() async throws -> Data { try photo.value.get() }
}

/// JPEG real de 2000×1000 generado en memoria (ImageIO), para el pipeline ≤1568px.
func makeJPEG(width: Int = 2000, height: Int = 1000) -> Data {
    #if canImport(CoreGraphics) && canImport(ImageIO)
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = ctx.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
    #else
    return Data()
    #endif
}

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

@Suite("G1 — tools glasses_show / glasses_camera")
struct GlassesToolsTests {

    static let validTree: JSONValue = .object([
        "type": .string("flexbox"), "background": .string("card"), "padding": .int(12), "spacing": .int(10),
        "children": .array([
            .object(["type": .string("text"), "content": .string("Mañana"), "style": .string("heading")]),
            .object(["type": .string("button_group"), "alignment": .string("end"), "buttons": .array([
                .object(["type": .string("button"), "label": .string("Listo"), "action": .string("dismiss")]),
            ])]),
        ]),
    ])

    @Test func showProyectaArbolesValidosYRechazaInvalidos() async {
        let host = MockToolHost()
        let tool = GlassesShowTool(host: host)
        #expect(tool.kind(for: .null) == .afferent)
        #expect(tool.operation(for: .null) == "project_card")
        #expect(tool.spec.name == "glasses_show")

        let ok = await tool.execute(.object(["tree": Self.validTree]))
        #expect(!ok.isError)
        #expect(host.projected.value.count == 1)

        let missing = await tool.execute(.object([:]))
        #expect(missing.isError)
        let bad = await tool.execute(.object(["tree": .object(["type": .string("flexbox"), "children": .array([
            .object(["type": .string("icon"), "name": .string("mic")])])])]))
        #expect(bad.isError)
        #expect(bad.content.contains("mic"))
        // 3 botones propios + Atrás = 4 > 3: se rechaza.
        let buttons = (0..<3).map { _ in JSONValue.object(["type": .string("button"), "label": .string("b"), "action": .string("dismiss")]) }
        let many = await tool.execute(.object(["tree": .object(["type": .string("flexbox"), "children": .array(buttons)])]))
        #expect(many.isError)
        #expect(host.projected.value.count == 1)

        host.accept.mutate { $0 = false }
        #expect(await tool.execute(.object(["tree": Self.validTree])).content == GlassesToolText.unavailable)
        #expect(await GlassesShowTool(host: nil).execute(.object(["tree": Self.validTree])).isError)
    }

    @Test func showRespetaElRateLimit() async {
        let clock = Locked(Date(timeIntervalSince1970: 0))
        let limiter = ProjectionRateLimiter(limit: 2, window: 3600, now: { clock.value })
        let tool = GlassesShowTool(host: MockToolHost(), limiter: limiter)
        let input: JSONValue = .object(["tree": Self.validTree])
        #expect(!(await tool.execute(input)).isError)
        #expect(!(await tool.execute(input)).isError)
        let third = await tool.execute(input)
        #expect(third.isError)
        #expect(third.content.contains("Límite"))
        clock.mutate { $0 = $0.addingTimeInterval(3601) }
        #expect(!(await tool.execute(input)).isError)
        #expect(limiter.limit == 2)
    }

    @Test func guardDeCuerpoSinGafas() async {
        let host = MockToolHost()
        host.active.mutate { $0 = false }
        #expect(await GlassesShowTool(host: host).bodyGuard(for: .null)?.content == GlassesToolText.unavailable)
        #expect(await GlassesCameraTool(host: host).bodyGuard(for: .null)?.isError == true)
        #expect(await GlassesShowTool(host: nil).bodyGuard(for: .null) != nil)
        host.active.mutate { $0 = true }
        #expect(await GlassesCameraTool(host: host).bodyGuard(for: .null) == nil)
    }

    @Test func camaraEsEferenteYAdjuntaLaFotoReducida() async throws {
        let host = MockToolHost()
        host.photo.mutate { $0 = .success(makeJPEG()) }
        let tool = GlassesCameraTool(host: host)
        #expect(tool.kind(for: .null) == .efferent)   // ask SIEMPRE (§8)
        #expect(tool.operation(for: .null) == "capture_pov")
        #expect(tool.confirmationSummary(for: .object(["reason": .string("Ver la etiqueta")])) == "Ver la etiqueta")
        #expect(tool.confirmationSummary(for: .null) == "Para ver lo que estás mirando.")

        let result = await tool.execute(.object([:]))
        #expect(!result.isError)
        #expect(result.content.contains("1568×784"))
        guard case .image(let media, let base64)? = result.attachments.first else {
            Issue.record("sin image block"); return
        }
        #expect(media == "image/jpeg")
        #expect(!base64.isEmpty)

        host.photo.mutate { $0 = .success(Data([1, 2, 3])) }
        #expect(await tool.execute(.null).content.contains("no pudo procesarse"))
        host.photo.mutate { $0 = .failure(MockError("hinges")) }
        #expect(await tool.execute(.null).content.contains("hinges"))
        #expect(await GlassesCameraTool(host: nil).execute(.null).isError)
    }

    @Test func sensorimotorAplicaElGuardAntesDelPermiso() async {
        let host = MockToolHost()
        host.active.mutate { $0 = false }
        let asked = Locked(0)
        struct Spy: ConfirmationProvider {
            let asked: Locked<Int>
            func confirm(_ request: ConfirmationRequest) async -> Bool { asked.mutate { $0 += 1 }; return true }
        }
        let sm = Sensorimotor(tools: [GlassesCameraTool(host: host)], confirmation: Spy(asked: asked))
        let result = await sm.execute(name: "glasses_camera", input: .object([:]))
        #expect(result.isError)
        #expect(result.content == GlassesToolText.unavailable)
        #expect(asked.value == 0, "sin gafas no se le pregunta nada al dueño")
        #expect(PatternKey.errorClass(fromToolResult: result.content) != "permission_denied")
    }

    @Test func confirmacionDeCamaraVaALasGafas() async {
        let phoneAsked = Locked(0)
        struct Phone: ConfirmationProvider {
            let asked: Locked<Int>
            func confirm(_ request: ConfirmationRequest) async -> Bool { asked.mutate { $0 += 1 }; return true }
        }
        let glassesAsked = Locked<[String]>([])
        let router = SurfaceConfirmationRouter(phone: Phone(asked: phoneAsked), glasses: { request in
            glassesAsked.mutate { $0.append(request.summary) }
            return true
        })
        let camera = ConfirmationRequest(tool: "glasses_camera", operation: "capture_pov", summary: "ver", input: .null)
        let calendar = ConfirmationRequest(tool: "calendar", operation: "create", summary: "evento", input: .null)
        #expect(await router.confirm(camera))
        #expect(glassesAsked.value == ["ver"])
        #expect(phoneAsked.value == 0)
        #expect(await router.confirm(calendar))
        #expect(phoneAsked.value == 1)
        // Fail-closed: sin gafas cableadas, la cámara se niega.
        #expect(await SurfaceConfirmationRouter(phone: Phone(asked: phoneAsked), glasses: nil).confirm(camera) == false)
    }

    @Test func laFotoEntraAlContextoJuntoAlToolResult() async throws {
        let queue = try AnimaDatabase.temporary()
        let store = SymbolicStore(queue: queue)
        let host = MockToolHost()
        host.photo.mutate { $0 = .success(makeJPEG(width: 400, height: 300)) }
        let round1: [ProviderEvent] = [
            .messageStart(id: "m1", model: "claude-opus-4-8"),
            .toolUseStart(id: "toolu_1", name: "glasses_camera"),
            .toolUseInputDelta(#"{"reason":"ver qué miras"}"#),
            .blockStop(index: 0),
            .messageDelta(stopReason: .toolUse, usage: Usage(inputTokens: 10, outputTokens: 5)),
            .messageStop,
        ]
        let provider = CapturingProvider([round1, .text("Es una pared azul.")])
        let loop = AgentLoop(provider: provider, store: store, telemetry: Telemetry(queue: queue),
                             router: ModelRouter(config: try TestConfig.providerConfig()), authMode: .apiKey,
                             token: "sk-ant-api03-xyz", clientTools: [GlassesCameraTool(host: host)],
                             serverTools: [],
                             confirmation: SurfaceConfirmationRouter(phone: FailClosedConfirmation(),
                                                                     glasses: { _ in true }),
                             sleep: { _ in })
        let sid = try store.startSession()
        for await _ in await loop.run(sessionId: sid, content: [.text("¿qué estoy viendo?")], surface: .glassesHUD) {}
        let second = try #require(provider.captures.value.last)
        let toolMessage = try #require(second.messages.last { $0.role == .user && $0.content.contains {
            if case .toolResult = $0 { return true } else { return false } } })
        guard case .toolResult(_, _, let isError) = toolMessage.content.first else { Issue.record("orden"); return }
        #expect(!isError)
        #expect(toolMessage.content.contains { if case .image = $0 { return true } else { return false } })
        #expect(try store.surfaces(sessionId: sid).allSatisfy { $0 == .glassesHUD })
    }
}

@Suite("G1 — ruta de audio HFP/A2DP y fin de turno")
struct GlassesVoicePolicyTests {

    final class FakeAudio: AudioSessionPort, @unchecked Sendable {
        let available: Bool
        let settlesOnAttempt: Int?   // en qué intento la ruta queda HFP (nil = nunca)
        let throwsOnHFP: Bool
        let attempts = Locked(0)
        let phoneMic = Locked(0)
        let a2dp = Locked(0)
        let deactivated = Locked(0)
        init(available: Bool, settlesOnAttempt: Int?, throwsOnHFP: Bool = false) {
            self.available = available
            self.settlesOnAttempt = settlesOnAttempt
            self.throwsOnHFP = throwsOnHFP
        }
        func hfpInputAvailable() -> Bool { available }
        func activateHFP() throws {
            attempts.mutate { $0 += 1 }
            if throwsOnHFP { throw MockError("route") }
        }
        func currentInputIsHFP() -> Bool { settlesOnAttempt.map { attempts.value >= $0 } ?? false }
        func activatePhoneMic() throws { phoneMic.mutate { $0 += 1 } }
        func activatePlaybackA2DP() throws { a2dp.mutate { $0 += 1 } }
        func deactivate() { deactivated.mutate { $0 += 1 } }
    }

    static let noSleep: @Sendable (TimeInterval) async -> Void = { _ in }

    @Test func hfpAsientaAlPrimerIntento() async {
        let audio = FakeAudio(available: true, settlesOnAttempt: 1)
        #expect(await AudioRoutePlanner.settleCapture(audio, sleep: Self.noSleep) == .glassesHFP)
        #expect(audio.attempts.value == 1)
        #expect(audio.phoneMic.value == 0)
    }

    @Test func reintentaUnaVezYLuegoDegradaAlTelefono() async {
        let second = FakeAudio(available: true, settlesOnAttempt: 2)
        #expect(await AudioRoutePlanner.settleCapture(second, sleep: Self.noSleep) == .glassesHFP)
        #expect(second.attempts.value == 2)

        let never = FakeAudio(available: true, settlesOnAttempt: nil)
        #expect(await AudioRoutePlanner.settleCapture(never, sleep: Self.noSleep) == .phoneMic)
        #expect(never.attempts.value == 2)   // intento + 1 reintento, no más
        #expect(never.phoneMic.value == 1)

        let broken = FakeAudio(available: true, settlesOnAttempt: 1, throwsOnHFP: true)
        #expect(await AudioRoutePlanner.settleCapture(broken, sleep: Self.noSleep) == .phoneMic)

        let noGlasses = FakeAudio(available: false, settlesOnAttempt: 1)
        #expect(await AudioRoutePlanner.settleCapture(noGlasses, sleep: Self.noSleep) == .phoneMic)
        #expect(noGlasses.attempts.value == 0)
    }

    @Test func esperaElAsentamientoDeLaRuta() async {
        let waited = Locked<[TimeInterval]>([])
        let audio = FakeAudio(available: true, settlesOnAttempt: 1)
        _ = await AudioRoutePlanner.settleCapture(audio, settle: 2, sleep: { s in waited.mutate { $0.append(s) } })
        #expect(waited.value == [2])
    }

    @Test func finDeTurnoPorPausa() {
        let t0 = Date(timeIntervalSince1970: 0)
        var d = TurnEndDetector(silence: 1.2, maxDuration: 30)
        d.start(at: t0)
        #expect(!d.isFinished(at: t0.addingTimeInterval(5)))   // no ha oído nada: sigue
        d.partial("qué", at: t0.addingTimeInterval(1))
        d.partial("qué tengo", at: t0.addingTimeInterval(1.5))
        d.partial("qué tengo ", at: t0.addingTimeInterval(2.0))   // mismo texto: no reinicia
        #expect(!d.isFinished(at: t0.addingTimeInterval(2.6)))
        #expect(d.isFinished(at: t0.addingTimeInterval(2.7)))
        #expect(d.transcript == "qué tengo")
        #expect(d.isFinished(at: t0.addingTimeInterval(31)))
        var empty = TurnEndDetector()
        #expect(!empty.isFinished(at: t0))
        empty.start(at: t0)
        #expect(empty.isFinished(at: t0.addingTimeInterval(30)))
    }

    @Test func vozSilenciosa() async {
        let silent = SilentVoice()
        #expect(await silent.capture(onRoute: { _ in }) == nil)
        silent.cancel()
        await silent.speak("hola")
        silent.stop()
    }
}

@Suite("G1 — host tardío de las tools")
struct LateBoundHostTests {
    @Test func sinSuperficieEsFailClosedYLuegoDelega() async throws {
        let late = LateBoundGlassesHost()
        #expect(await late.glassesActive() == false)
        #expect(await late.project(HUDFlexBox(children: [])) == false)
        await #expect(throws: GlassesBodyError.self) { try await late.capturePOV() }
        let request = ConfirmationRequest(tool: "glasses_camera", operation: "o", summary: "s", input: .null)
        #expect(await late.confirm(request) == false)

        let host = MockToolHost()
        host.photo.mutate { $0 = .success(Data([9])) }
        late.bind(host, confirm: { _ in true })
        #expect(await late.glassesActive())
        #expect(await late.project(HUDFlexBox(children: [])))
        #expect(try await late.capturePOV() == Data([9]))
        #expect(await late.confirm(request))
    }
}
