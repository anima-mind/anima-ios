import Foundation
import Testing
@testable import AnimaKit

@Suite("Camera.photo — captura standalone con fallback al stream (DAT 1.0)")
struct GlassesPhotoCaptureTests {

    final class Script: @unchecked Sendable {
        let standaloneResults: Locked<[Result<Data, Error>]>
        let streamResult: Result<Data, Error>
        let standaloneCalls = Locked(0)
        let streamCalls = Locked(0)
        let paths = Locked<[(GlassesPhotoCapture.Path, String?)]>([])

        init(standalone: [Result<Data, Error>], stream: Result<Data, Error> = .success(Data([0x57]))) {
            standaloneResults = Locked(standalone)
            streamResult = stream
        }

        func run() async throws -> Data {
            try await GlassesPhotoCapture.capture(
                standalone: {
                    self.standaloneCalls.mutate { $0 += 1 }
                    var next: Result<Data, Error> = .failure(MockError("sin guion"))
                    self.standaloneResults.mutate { if !$0.isEmpty { next = $0.removeFirst() } }
                    return try next.get()
                },
                stream: {
                    self.streamCalls.mutate { $0 += 1 }
                    return try self.streamResult.get()
                },
                onPath: { path, why in self.paths.mutate { $0.append((path, why)) } })
        }
    }

    static let hiRes = Data([0xFF, 0xD8, 0xFF, 0x01])

    @Test func fotoDirectaOK() async throws {
        let script = Script(standalone: [.success(Self.hiRes)])
        #expect(try await script.run() == Self.hiRes)
        #expect(script.standaloneCalls.value == 1)
        #expect(script.streamCalls.value == 0)
        #expect(script.paths.value.map(\.0) == [.standalone])
    }

    @Test func noSoportadaCaeAlStream() async throws {
        let script = Script(standalone: [.failure(GlassesPhotoError.unsupported("serviceUnavailable"))])
        #expect(try await script.run() == Data([0x57]))
        #expect(script.standaloneCalls.value == 1, "no-soportado no se reintenta")
        #expect(script.streamCalls.value == 1)
        #expect(script.paths.value.first?.0 == .stream)
        #expect(script.paths.value.first?.1 == "serviceUnavailable")
    }

    @Test func arranqueIntermitenteSeReintentaUnaVez() async throws {
        let script = Script(standalone: [.failure(GlassesPhotoError.setupFailed("sessionSetupFailed")),
                                         .success(Self.hiRes)])
        #expect(try await script.run() == Self.hiRes)
        #expect(script.standaloneCalls.value == 2)
        #expect(script.streamCalls.value == 0)
        #expect(script.paths.value.map(\.0) == [.standaloneRetry])
    }

    @Test func arranqueFallaDosVecesCaeAlStream() async throws {
        let script = Script(standalone: [.failure(GlassesPhotoError.setupFailed("timeout")),
                                         .failure(GlassesPhotoError.setupFailed("stopped"))])
        #expect(try await script.run() == Data([0x57]))
        #expect(script.standaloneCalls.value == 2)
        #expect(script.paths.value.first?.1 == "stopped")
    }

    @Test func reintentoNoSoportadoCaeAlStream() async throws {
        let script = Script(standalone: [.failure(GlassesPhotoError.setupFailed("timeout")),
                                         .failure(GlassesPhotoError.unsupported("notReady"))])
        #expect(try await script.run() == Data([0x57]))
        #expect(script.paths.value.first?.1 == "notReady")
    }

    @Test func falloDeCapturaNoCaeAlStream() async throws {
        let script = Script(standalone: [.failure(GlassesPhotoError.failed("permissionDenied"))])
        await #expect(throws: GlassesPhotoError.failed("permissionDenied")) { try await script.run() }
        #expect(script.streamCalls.value == 0)
    }

    @Test func falloDelReintentoSePropaga() async throws {
        let script = Script(standalone: [.failure(GlassesPhotoError.setupFailed("timeout")),
                                         .failure(GlassesPhotoError.failed("busy"))])
        await #expect(throws: GlassesPhotoError.failed("busy")) { try await script.run() }
        #expect(script.streamCalls.value == 0)
    }

    @Test func falloDelStreamSePropaga() async throws {
        let script = Script(standalone: [.failure(GlassesPhotoError.unsupported("serviceUnavailable"))],
                            stream: .failure(MockError("timeout")))
        await #expect(throws: MockError.self) { try await script.run() }
        #expect(script.paths.value.isEmpty)
    }

    @Test func descripcionesLegibles() {
        #expect(GlassesPhotoError.setupFailed("x").description.contains("no arrancó"))
        #expect(GlassesPhotoError.unsupported("x").description.contains("no soportada"))
        #expect(GlassesPhotoError.failed("x").description.contains("falló"))
    }
}
