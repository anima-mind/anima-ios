// DATGlassesRuntime.swift — capa HUMILDE sobre el DAT SDK 1.0.0 (Meta Wearables).
// Sin lógica propia: traduce los puertos de AnimaKit (GlassesRuntime /
// GlassesSessionPort / GlassesDisplayPort) a MWDATCore/MWDATDisplay/MWDATCamera.
// Toda la lógica (sesión única, generaciones, re-send, dolencias) vive en
// GlassesBody (AnimaKit, testeada). Calcado del DATManager de Relay, verificado
// en hardware real. Verificable SOLO con gafas (aceptación G0/G1, doc 05 §7).
//
// ⚠️ Este archivo NO importa SwiftUI: `Text`/`Button`/`Image` colisionarían con
// los de MWDATDisplay (doc Relay §5).

#if canImport(MWDATCore) && canImport(MWDATDisplay)
import Foundation
import AnimaKit
import MWDATCore
import MWDATDisplay
#if canImport(MWDATCamera)
import MWDATCamera
#endif

final class DATGlassesRuntime: GlassesRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var _wearables: (any WearablesInterface)?
    /// El selector ÚNICO de toda la vida de la app (regla 2 / sample DisplayAccess).
    private var _selector: AutoDeviceSelector?

    private var wearables: (any WearablesInterface)? { lock.lock(); defer { lock.unlock() }; return _wearables }
    private var selector: AutoDeviceSelector? { lock.lock(); defer { lock.unlock() }; return _selector }

    func configure() throws {
        do {
            try Wearables.configure()
        } catch WearablesError.alreadyConfigured {
            // idempotente
        }
        let shared = Wearables.shared
        lock.lock()
        _wearables = shared
        _selector = AutoDeviceSelector(wearables: shared) { $0.supportsDisplay() }
        lock.unlock()
    }

    func registrationState() async -> GlassesRegistration {
        wearables.map { Self.map($0.registrationState) } ?? .unavailable
    }

    func registrationUpdates() -> AsyncStream<GlassesRegistration> {
        guard let wearables else { return AsyncStream { $0.finish() } }
        return AsyncStream { continuation in
            let task = Task {
                for await state in wearables.registrationStateStream() { continuation.yield(Self.map(state)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Devices + link + compatibilidad. Bag NUEVO por refresh; el viejo se
    /// cancela aparte (no reusar: cancelaría los tokens nuevos — Relay §4).
    func deviceUpdates() -> AsyncStream<[GlassesDeviceSnapshot]> {
        guard let wearables else { return AsyncStream { $0.finish() } }
        return AsyncStream { continuation in
            let task = Task {
                var bag = ListenerTokenBag()
                for await ids in wearables.devicesStream() {
                    let stale = bag
                    Task { await stale.cancelAll() }
                    bag = ListenerTokenBag()
                    let emit: @Sendable () -> Void = { continuation.yield(Self.snapshots(wearables, ids)) }
                    for id in ids {
                        guard let device = wearables.deviceForIdentifier(id) else { continue }
                        device.addLinkStateListener { _ in emit() }.store(in: bag)
                        device.addCompatibilityListener { _ in emit() }.store(in: bag)
                        // 1.0: batería/temperatura/don llegan por DeviceState
                        // (don → don-wake en GlassesActivation).
                        device.addDeviceStateListener { state in
                            Self.donCache.set(id, Self.map(state.donState))
                            emit()
                        }.store(in: bag)
                    }
                    emit()
                }
                await bag.cancelAll()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func startRegistration() async throws {
        guard let wearables else { throw AbsentGlassesRuntime.Unavailable() }
        do {
            try await wearables.startRegistration()
        } catch RegistrationError.alreadyRegistered {
            // ya registrado
        }
    }

    func startUnregistration() async throws {
        guard let wearables else { throw AbsentGlassesRuntime.Unavailable() }
        try await wearables.startUnregistration()
    }

    func handleURL(_ url: URL) async throws -> Bool {
        guard let wearables else { return false }
        return try await wearables.handleUrl(url)
    }

    func openDATGlassesAppUpdate() async throws {
        guard let wearables else { throw AbsentGlassesRuntime.Unavailable() }
        try await wearables.openDATGlassesAppUpdate()
    }

    func makeSession() throws -> any GlassesSessionPort {
        guard let wearables, let selector else { throw AbsentGlassesRuntime.Unavailable() }
        let session = try wearables.createSession(deviceSelector: selector)
        return DATSession(session: session, wearables: wearables)
    }

    // MARK: - Mapeos

    static func map(_ state: RegistrationState) -> GlassesRegistration {
        switch state {
        case .unavailable: return .unavailable
        case .available: return .available
        case .registering: return .registering
        case .registered: return .registered
        @unknown default: return .unavailable
        }
    }

    static let donCache = DATDonCache()

    static func map(_ don: DonState) -> GlassesDonState {
        switch don {
        case .donned: return .donned
        case .doffed: return .doffed
        default: return .unknown
        }
    }

    static func snapshots(_ wearables: any WearablesInterface, _ ids: [DeviceIdentifier]) -> [GlassesDeviceSnapshot] {
        ids.compactMap { id in
            guard let device = wearables.deviceForIdentifier(id) else { return nil }
            let link: GlassesLink
            switch device.linkState {
            case .connected: link = .connected
            case .connecting: link = .connecting
            default: link = .disconnected
            }
            let compatibility: GlassesCompatibility
            switch device.compatibility() {
            case .compatible: compatibility = .compatible
            case .deviceUpdateRequired: compatibility = .deviceUpdateRequired
            case .sdkUpdateRequired: compatibility = .sdkUpdateRequired
            default: compatibility = .undefined
            }
            // El valor del listener manda (llega antes de que el accessor se entere).
            let don = donCache.get(id) ?? map(device.donState)
            return GlassesDeviceSnapshot(id: id, name: device.nameOrId(), link: link,
                                         compatibility: compatibility,
                                         supportsDisplay: device.supportsDisplay(),
                                         batteryPercent: device.batteryLevel,
                                         donState: don)
        }
    }
}

/// Último DonState reportado por `addDeviceStateListener`, por device.
final class DATDonCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DeviceIdentifier: GlassesDonState] = [:]
    func set(_ id: DeviceIdentifier, _ value: GlassesDonState) { lock.lock(); values[id] = value; lock.unlock() }
    func get(_ id: DeviceIdentifier) -> GlassesDonState? { lock.lock(); defer { lock.unlock() }; return values[id] }
}

// MARK: - Sesión

final class DATSession: GlassesSessionPort, @unchecked Sendable {
    private let session: DeviceSession
    private let wearables: any WearablesInterface

    init(session: DeviceSession, wearables: any WearablesInterface) {
        self.session = session
        self.wearables = wearables
    }

    func start() throws { try session.start() }
    func stop() { session.stop() }

    /// ≥0.9: termina al llegar `.stopped` (GlassesBody re-suscribe por generación).
    func stateUpdates() -> AsyncStream<GlassesSessionState> {
        let source = session.stateStream()
        return AsyncStream { continuation in
            let task = Task {
                for await state in source {
                    switch state {
                    case .idle: continuation.yield(.idle)
                    case .starting: continuation.yield(.starting)
                    case .started: continuation.yield(.started)
                    case .paused: continuation.yield(.paused)
                    case .stopping: continuation.yield(.stopping)
                    case .stopped: continuation.yield(.stopped)
                    @unknown default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func faultUpdates() -> AsyncStream<GlassesFault> {
        let source = session.errorStream()
        return AsyncStream { continuation in
            let task = Task {
                for await error in source { continuation.yield(Self.map(error)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func map(_ error: DeviceSessionError) -> GlassesFault {
        switch error {
        case .thermalCritical: return .thermalCritical
        case .thermalEmergency: return .thermalEmergency
        case .peakPowerShutdown: return .peakPowerShutdown
        case .batteryCritical: return .batteryCritical
        case .datAppOnTheGlassesUpdateRequired: return .datAppUpdateRequired
        case .insufficientSDKVersion: return .sdkUpdateRequired     // 1.0, terminal
        case .dwaOutOfStuRange: return .compatibilityWarning        // 1.0, no bloqueante
        case .noEligibleDevice: return .noEligibleDevice
        default: return .other(error.description)
        }
    }

    func addDisplay() throws -> any GlassesDisplayPort {
        DATDisplay(display: try session.addDisplay())
    }

    // MARK: Cámara POV (MWDATCamera, re-verificado contra el .swiftinterface 1.0.0:
    // addCamera(config:) → Camera?.stream → start → capturePhoto(.jpeg) →
    // photoDataPublisher). ⚠️ Pendiente de device: convivencia display+cámara en
    // la misma sesión y latencia real del primer frame.
    func capturePhoto() async throws -> Data {
        #if canImport(MWDATCamera)
        let status = try await wearables.checkPermissionStatus(.camera)
        if status != .granted {
            guard try await wearables.requestPermission(.camera) == .granted else {
                throw DATCameraError.permissionDenied
            }
        }
        guard let camera = try session.addCamera(config: StreamConfiguration()) else {
            throw DATCameraError.unavailable
        }
        defer { camera.stop() }
        let stream = camera.stream
        let once = DATOnce<Result<Data, Error>>()
        var tokens: [any AnyListenerToken] = []
        let photo: Data = try await withCheckedThrowingContinuation { continuation in
            once.set { continuation.resume(with: $0) }
            tokens.append(stream.photoDataPublisher.listen { photo in once.fire(.success(photo.data)) })
            tokens.append(stream.errorPublisher.listen { error in once.fire(.failure(error)) })
            tokens.append(stream.statePublisher.listen { state in
                if state == .streaming { _ = stream.capturePhoto(format: .jpeg) }
            })
            stream.start()
            if stream.state == .streaming { _ = stream.capturePhoto(format: .jpeg) }
            Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                once.fire(.failure(DATCameraError.timeout))
            }
        }
        for token in tokens { await token.cancel() }
        stream.stop()
        return photo
        #else
        throw DATCameraError.unavailable
        #endif
    }
}

enum DATCameraError: Error, CustomStringConvertible {
    case unavailable, permissionDenied, timeout
    var description: String {
        switch self {
        case .unavailable: return "la cámara de las gafas no está disponible"
        case .permissionDenied: return "sin permiso de cámara en Meta AI"
        case .timeout: return "la foto no llegó a tiempo"
        }
    }
}

/// Resuelve una continuation una sola vez (listeners del SDK pueden repetir).
final class DATOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((T) -> Void)?
    func set(_ handler: @escaping (T) -> Void) { lock.lock(); self.handler = handler; lock.unlock() }
    func fire(_ value: T) {
        lock.lock(); let h = handler; handler = nil; lock.unlock()
        h?(value)
    }
}

// MARK: - Display

final class DATDisplay: GlassesDisplayPort, @unchecked Sendable {
    private let display: Display
    private let lock = NSLock()
    private var token: (any AnyListenerToken)?

    init(display: Display) { self.display = display }

    func start() { display.start() }
    func stop() {
        display.stop()
        lock.lock(); let t = token; token = nil; lock.unlock()
        if let t { Task { await t.cancel() } }
    }

    func stateUpdates() -> AsyncStream<GlassesDisplayState> {
        AsyncStream { continuation in
            let token = display.statePublisher.listen { state in
                switch state {
                case .starting: continuation.yield(.starting)
                case .started: continuation.yield(.started)
                case .stopping: continuation.yield(.stopping)
                case .stopped: continuation.yield(.stopped)
                @unknown default: break
                }
            }
            lock.lock(); self.token = token; lock.unlock()
            continuation.onTermination = { _ in Task { await token.cancel() } }
        }
    }

    func send(_ view: HUDView, onAction: @escaping @Sendable (HUDActionID) -> Void) async throws {
        try await display.send(HUDDATMapper.flexBox(view.root, onAction))
    }
}

// MARK: - HUDView (datos puros) → árbol DAT real

enum HUDDATMapper {
    static func flexBox(_ box: HUDFlexBox, _ onAction: @escaping @Sendable (HUDActionID) -> Void) -> FlexBox {
        let children: [any ViewComponent] = box.children.map { component($0, onAction) }
        // Pasar la función (no un closure literal) evita la transformación del
        // result builder: el array ya está construido.
        let content: () -> [any ViewComponent] = { children }
        var flex = FlexBox(direction: direction(box.direction), spacing: CGFloat(box.spacing),
                           alignment: alignment(box.alignment), crossAlignment: alignment(box.crossAlignment),
                           wrap: false, padding: box.padding.map { EdgeInsets(all: CGFloat($0)) },
                           content: content)
        if box.background == .card { flex = flex.background(.card) }
        if let tap = box.onTap { flex = flex.onTap { onAction(tap) } }
        return flex
    }

    static func component(_ node: HUDNode, _ onAction: @escaping @Sendable (HUDActionID) -> Void) -> any ViewComponent {
        switch node {
        case .flexBox(let box):
            return flexBox(box, onAction)
        case .text(let text):
            return Text(text.content, style: textStyle(text.style), color: text.color == .primary ? .primary : .secondary)
        case .icon(let icon):
            return Icon(name: iconName(icon.name), style: icon.style == .filled ? .filled : .outline)
        case .image(let image):
            return Image(uri: image.uri, sizePreset: image.size == .icon ? .icon : .fill,
                         cornerRadius: cornerRadius(image.cornerRadius))
        case .button(let button):
            return self.button(button, onAction)
        case .buttonGroup(let group):
            let buttons = group.buttons.map { self.button($0, onAction) }
            let content: () -> [Button] = { buttons }
            return ButtonGroup(alignment: groupAlignment(group.alignment), content: content)
        }
    }

    static func button(_ b: HUDButton, _ onAction: @escaping @Sendable (HUDActionID) -> Void) -> Button {
        let action = b.action
        return Button(label: b.label, style: buttonStyle(b.style), iconName: b.icon.map(iconName)) { onAction(action) }
    }

    /// El catálogo HUDIcon es 1:1 con IconName (test de catálogo en AnimaKit).
    static func iconName(_ icon: HUDIcon) -> IconName { IconName(rawValue: icon.rawValue) ?? .circle8RaysLarge }

    static func textStyle(_ s: HUDTextStyle) -> TextStyle {
        switch s { case .heading: return .heading; case .body: return .body; case .meta: return .meta }
    }
    static func buttonStyle(_ s: HUDButtonStyle) -> ButtonStyle {
        switch s { case .primary: return .primary; case .secondary: return .secondary; case .outline: return .outline }
    }
    static func direction(_ d: HUDDirection) -> Direction {
        switch d {
        case .column: return .column
        case .row: return .row
        case .columnReverse: return .columnReverse
        case .rowReverse: return .rowReverse
        }
    }
    static func alignment(_ a: HUDAlignment) -> Alignment {
        switch a { case .start: return .start; case .center: return .center; case .end: return .end; case .stretch: return .stretch }
    }
    static func groupAlignment(_ a: HUDButtonGroupAlignment) -> ButtonGroupAlignment {
        switch a { case .start: return .start; case .center: return .center; case .end: return .end }
    }
    static func cornerRadius(_ r: HUDCornerRadius) -> CornerRadius {
        switch r { case .none: return .none; case .small: return .small; case .medium: return .medium }
    }
}
#endif
