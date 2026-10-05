// GlassesPorts.swift — la costura con el DAT SDK (doc 05 §3.1). Protocolos FINOS
// y mockeables: el SDK real (MWDATCore/MWDATDisplay/MWDATCamera, iOS-only y
// binario) vive SOLO en el app shell (App/Glasses/DATGlassesRuntime.swift) y
// conforma estos puertos; AnimaKit sigue compilando y testeando en macOS.
// Los enums calcan los del `.swiftinterface` 1.0.0 (RegistrationState,
// Compatibility, LinkState, DeviceSessionState, DisplayState, DeviceSessionError
// + StreamError) sin importarlos.

import Foundation

public enum GlassesRegistration: String, Sendable, Equatable {
    case unavailable, available, registering, registered
}

public enum GlassesCompatibility: String, Sendable, Equatable {
    case undefined, compatible, deviceUpdateRequired, sdkUpdateRequired
}

public enum GlassesLink: String, Sendable, Equatable {
    case disconnected, connecting, connected
}

/// DAT 1.0.0 `DonState`: si el dueño lleva puestas las gafas (`Device.donState`,
/// llega por `addDeviceStateListener`).
public enum GlassesDonState: String, Sendable, Equatable {
    case unknown, doffed, donned
}

/// Un device visto por el runtime (link + compatibilidad llegan tarde: el
/// adapter re-emite el snapshot en cada listener, regla 3).
public struct GlassesDeviceSnapshot: Sendable, Equatable {
    public var id: String
    public var name: String
    public var link: GlassesLink
    public var compatibility: GlassesCompatibility
    public var supportsDisplay: Bool
    /// DAT 1.0.0: `Device.batteryLevel` (nil hasta que las gafas lo reportan).
    public var batteryPercent: Int?
    /// DAT 1.0.0: `Device.donState` (puestas / quitadas).
    public var donState: GlassesDonState

    public init(id: String, name: String, link: GlassesLink, compatibility: GlassesCompatibility,
                supportsDisplay: Bool = true, batteryPercent: Int? = nil, donState: GlassesDonState = .unknown) {
        self.id = id
        self.name = name
        self.link = link
        self.compatibility = compatibility
        self.supportsDisplay = supportsDisplay
        self.batteryPercent = batteryPercent
        self.donState = donState
    }
}

public enum GlassesSessionState: String, Sendable, Equatable {
    case idle, starting, started, paused, stopping, stopped
}

public enum GlassesDisplayState: String, Sendable, Equatable {
    case starting, started, stopping, stopped
}

/// Fallos físicos/de sesión (DeviceSessionError + StreamError del SDK).
public enum GlassesFault: Sendable, Equatable {
    case thermalCritical
    case thermalEmergency
    case peakPowerShutdown
    case batteryCritical
    case datAppUpdateRequired
    /// 1.0 `insufficientSDKVersion`: TERMINAL, hay que publicar la app con un SDK nuevo.
    case sdkUpdateRequired
    /// 1.0 `dwaOutOfStuRange`: aviso NO bloqueante de compatibilidad; la sesión sigue.
    case compatibilityWarning
    case noEligibleDevice
    case hingesClosed
    case other(String)
}

public protocol GlassesDisplayPort: AnyObject, Sendable {
    func start()
    func stop()
    /// Termina cuando el display (o su sesión) se detiene.
    func stateUpdates() -> AsyncStream<GlassesDisplayState>
    /// `display.send()` — reemplaza TODA la vista. `onAction` recibe los
    /// callbacks `onClick`/`onTap` del árbol como IDs.
    func send(_ view: HUDView, onAction: @escaping @Sendable (HUDActionID) -> Void) async throws
}

public protocol GlassesSessionPort: AnyObject, Sendable {
    func start() throws
    func stop()
    /// ≥0.9: el stream TERMINA al llegar `.stopped` (re-suscribir por sesión).
    func stateUpdates() -> AsyncStream<GlassesSessionState>
    func faultUpdates() -> AsyncStream<GlassesFault>
    /// Un display por sesión.
    func addDisplay() throws -> any GlassesDisplayPort
    /// Foto POV (MWDATCamera: addCamera → stream.capturePhoto(.jpeg)).
    func capturePhoto() async throws -> Data
}

public protocol GlassesRuntime: Sendable {
    /// `Wearables.configure()` (lee el bloque MWDAT del Info.plist).
    func configure() throws
    func registrationState() async -> GlassesRegistration
    func registrationUpdates() -> AsyncStream<GlassesRegistration>
    /// Devices + link + compatibilidad (el adapter usa un ListenerTokenBag NUEVO
    /// por refresh y cancela el viejo — regla 4).
    func deviceUpdates() -> AsyncStream<[GlassesDeviceSnapshot]>
    func startRegistration() async throws
    func startUnregistration() async throws
    func handleURL(_ url: URL) async throws -> Bool
    func openDATGlassesAppUpdate() async throws
    /// Crea UNA sesión con el selector ÚNICO del runtime (regla 2).
    func makeSession() throws -> any GlassesSessionPort
}

/// Runtime nulo: la app sin gafas (UI tests, simulador sin config, o sin SDK).
/// Todo reporta "no disponible" y nada lanza en silencio.
public struct AbsentGlassesRuntime: GlassesRuntime {
    public struct Unavailable: Error, Equatable, CustomStringConvertible {
        public init() {}
        public var description: String { "gafas no disponibles en esta build" }
    }
    public init() {}
    public func configure() throws { throw Unavailable() }
    public func registrationState() async -> GlassesRegistration { .unavailable }
    public func registrationUpdates() -> AsyncStream<GlassesRegistration> { AsyncStream { $0.finish() } }
    public func deviceUpdates() -> AsyncStream<[GlassesDeviceSnapshot]> { AsyncStream { $0.finish() } }
    public func startRegistration() async throws { throw Unavailable() }
    public func startUnregistration() async throws { throw Unavailable() }
    public func handleURL(_ url: URL) async throws -> Bool { false }
    public func openDATGlassesAppUpdate() async throws { throw Unavailable() }
    public func makeSession() throws -> any GlassesSessionPort { throw Unavailable() }
}
