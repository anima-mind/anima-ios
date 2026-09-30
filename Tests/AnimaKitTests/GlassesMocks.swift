import Foundation
import Testing
@testable import AnimaKit

// Dobles del DAT SDK para `swift test` en macOS. MockDeviceKit del SDK NO es
// viable aquí: es un XCFramework iOS-only y, además, su `GlassesModel` no
// incluye Meta Ray-Ban Display (no simula Display). Por eso: puertos finos
// (GlassesPorts) + estos mocks, que reproducen el contrato 0.9.0 verificado en
// hardware por Relay (streams que TERMINAN en .stopped, display que duerme).

struct MockError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

final class MockDisplay: GlassesDisplayPort, @unchecked Sendable {
    private let (stream, cont) = AsyncStream<GlassesDisplayState>.makeStream()
    let sent = Locked<[HUDView]>([])
    let starts = Locked(0)
    let stops = Locked(0)
    let handler = Locked<(@Sendable (HUDActionID) -> Void)?>(nil)
    let sendError = Locked<Error?>(nil)
    let autoStart: Bool

    init(autoStart: Bool = true) { self.autoStart = autoStart }

    func start() {
        starts.mutate { $0 += 1 }
        cont.yield(.starting)
        if autoStart { cont.yield(.started) }
    }
    func stop() {
        stops.mutate { $0 += 1 }
        cont.yield(.stopped)
        cont.finish()
    }
    func stateUpdates() -> AsyncStream<GlassesDisplayState> { stream }
    func send(_ view: HUDView, onAction: @escaping @Sendable (HUDActionID) -> Void) async throws {
        if let error = sendError.value { throw error }
        sent.mutate { $0.append(view) }
        handler.mutate { $0 = onAction }
    }
    /// Simula sleep → wake del display (el SDK vuelve a `.started`).
    func wake() { cont.yield(.started) }
    func sleep() { cont.yield(.stopped) }
    /// Simula un pinch sobre un botón del árbol enviado.
    func tap(_ action: HUDActionID) { handler.value?(action) }
}

final class MockSession: GlassesSessionPort, @unchecked Sendable {
    private let (states, stateCont) = AsyncStream<GlassesSessionState>.makeStream()
    private let (faults, faultCont) = AsyncStream<GlassesFault>.makeStream()
    let display: MockDisplay
    let started = Locked(0)
    let stopped = Locked(0)
    let startError: Error?
    let displayError: Error?
    let photo = Locked<Result<Data, Error>>(.success(Data([0xFF, 0xD8, 0xFF])))
    let autoStart: Bool

    init(display: MockDisplay = MockDisplay(), autoStart: Bool = true, startError: Error? = nil,
         displayError: Error? = nil) {
        self.display = display
        self.autoStart = autoStart
        self.startError = startError
        self.displayError = displayError
    }

    func start() throws {
        if let startError { throw startError }
        started.mutate { $0 += 1 }
        stateCont.yield(.starting)
        if autoStart { stateCont.yield(.started) }
    }
    func stop() {
        stopped.mutate { $0 += 1 }
        stateCont.yield(.stopped)
        stateCont.finish()
        faultCont.finish()
    }
    func stateUpdates() -> AsyncStream<GlassesSessionState> { states }
    func faultUpdates() -> AsyncStream<GlassesFault> { faults }
    func addDisplay() throws -> any GlassesDisplayPort {
        if let displayError { throw displayError }
        return display
    }
    func capturePhoto() async throws -> Data { try photo.value.get() }

    /// El SDK termina la sesión por su cuenta (back físico / apagado).
    func endFromDevice() {
        stateCont.yield(.stopped)
        stateCont.finish()
        faultCont.finish()
    }
    func fault(_ f: GlassesFault) { faultCont.yield(f) }
    func emit(_ s: GlassesSessionState) { stateCont.yield(s) }

    var isLive: Bool { started.value > stopped.value }
}

final class MockRuntime: GlassesRuntime, @unchecked Sendable {
    private let (regStream, regCont) = AsyncStream<GlassesRegistration>.makeStream()
    private let (devStream, devCont) = AsyncStream<[GlassesDeviceSnapshot]>.makeStream()
    let registration: Locked<GlassesRegistration>
    let configureError: Error?
    let sessions = Locked<[MockSession]>([])
    let makeError = Locked<Error?>(nil)
    let nextSession = Locked<(() -> MockSession)?>(nil)
    let registerCalls = Locked(0)
    let unregisterCalls = Locked(0)
    let updateCalls = Locked(0)
    let urls = Locked<[URL]>([])

    init(registration: GlassesRegistration = .registered, configureError: Error? = nil) {
        self.registration = Locked(registration)
        self.configureError = configureError
    }

    func configure() throws { if let configureError { throw configureError } }
    func registrationState() async -> GlassesRegistration { registration.value }
    func registrationUpdates() -> AsyncStream<GlassesRegistration> { regStream }
    func deviceUpdates() -> AsyncStream<[GlassesDeviceSnapshot]> { devStream }
    func startRegistration() async throws { registerCalls.mutate { $0 += 1 } }
    func startUnregistration() async throws { unregisterCalls.mutate { $0 += 1 } }
    func handleURL(_ url: URL) async throws -> Bool { urls.mutate { $0.append(url) }; return true }
    func openDATGlassesAppUpdate() async throws { updateCalls.mutate { $0 += 1 } }
    func makeSession() throws -> any GlassesSessionPort {
        if let error = makeError.value { throw error }
        let session = nextSession.value?() ?? MockSession()
        sessions.mutate { $0.append(session) }
        return session
    }

    func setRegistration(_ r: GlassesRegistration) { registration.mutate { $0 = r }; regCont.yield(r) }
    func setDevices(_ d: [GlassesDeviceSnapshot]) { devCont.yield(d) }
    var liveSessions: Int { sessions.value.filter(\.isLive).count }
    var lastSession: MockSession? { sessions.value.last }

    static let display = GlassesDeviceSnapshot(id: "g1", name: "Meta Ray-Ban Display", link: .connected,
                                               compatibility: .compatible, supportsDisplay: true)
}

/// Espera activa acotada (los streams del actor se procesan en tasks).
func eventually(_ timeout: TimeInterval = 2, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

/// Un GlassesBody con un device Display conectado y compatible, listo para activar.
func readyBody(_ runtime: MockRuntime = MockRuntime(), realRegister: RealRegister? = nil) async -> GlassesBody {
    let body = GlassesBody(runtime: runtime, realRegister: realRegister)
    await body.start()
    runtime.setDevices([MockRuntime.display])
    _ = await eventually { await body.currentStatus().body == .dormant }
    return body
}
