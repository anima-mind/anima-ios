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

    func openFirmwareUpdate() async throws {
        guard let wearables else { throw AbsentGlassesRuntime.Unavailable() }
        try await wearables.openFirmwareUpdate()
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
                                         donState: don,
                                         deviceType: device.deviceType().rawValue,
                                         thermal: "\(device.thermalLevel)")
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

    // MARK: Cámara POV (MWDATCamera 1.0.0, re-verificado contra el .swiftinterface)
    // Política (reintento + fallback) en GlassesPhotoCapture; permiso ANTES del
    // tope, tope global, una captura en vuelo y cancelación en GlassesBody
    // (AnimaKit, testeadas). Aquí:
    //   0. la sesión debe estar `.started` (pausada = transportes suspendidos);
    //   1. permiso de cámara (Meta AI, ida y vuelta) con tope + re-chequeo, en
    //      `ensureCameraPermission`, fuera del tope de la foto;
    //   2. `Camera.photo` standalone: listeners ANTES de `photo.start()`, captura
    //      en el primer `.started` FUERA del callback del listener (en el main
    //      actor, como el sample oficial), `.stopped` = GlassesStandaloneStop;
    //   3. fallback: el stream (stream.start → .streaming → capturePhoto(.jpeg)).
    // Cada intento: cámara NUEVA (una detenida queda inválida), continuation
    // NO lanzante resuelta UNA vez (GlassesOnce: éxito, error, tope o cancelación)
    // y teardown en orden fijo y una sola vez: tokens → photo/stream.stop() →
    // camera.stop(). Ningún listener toca la cámara tras resolverse el intento.
    func ensureCameraPermission(onPrompt: @escaping @Sendable () -> Void) async throws {
        #if canImport(MWDATCamera)
        let diag = GlassesDiagnostics.shared
        let wearables = self.wearables
        try await GlassesCameraPermission.ensure(
            check: { try await wearables.checkPermissionStatus(.camera) == .granted },
            request: { try await wearables.requestPermission(.camera) == .granted },
            timeout: Self.permissionTimeout,
            onPrompt: onPrompt,
            log: { diag.record(.photo, $0) })
        #else
        throw GlassesPhotoError.unavailable("build sin MWDATCamera")
        #endif
    }

    func capturePhoto() async throws -> Data {
        #if canImport(MWDATCamera)
        let diag = GlassesDiagnostics.shared
        guard session.state == .started else {
            diag.record(.photo, "sesión \(session.state) — sin captura")
            throw GlassesPhotoError.failed("la sesión de las gafas no está activa (\(session.state))")
        }
        let session = self.session
        return try await GlassesPhotoCapture.capture(
            standalone: { try await Self.standalonePhoto(session) },
            stream: { try await Self.streamPhoto(session) },
            onPath: { path, why in
                diag.record(.photo, "entregada por \(path.rawValue)\(why.map { " (\($0))" } ?? "")")
            })
        #else
        throw GlassesPhotoError.unavailable("build sin MWDATCamera")
        #endif
    }

    #if canImport(MWDATCamera)
    /// Resolución de la standalone: `.large` + `.high`. `.full` (sensor nativo) es
    /// el camino más lento según la doc y el pipeline baja a ≤1568 px igual
    /// (ImageDownscaler), así que pagaría latencia de transferencia por nada.
    static let photoResolution: PhotoResolution = .large
    static let photoQuality: PhotoQuality = .high
    static let permissionTimeout: TimeInterval = 90
    static let photoStartTimeout: TimeInterval = 6
    static let photoTimeout: TimeInterval = 25
    static let streamTimeout: TimeInterval = 15

    @MainActor
    static func standalonePhoto(_ session: DeviceSession) async throws -> Data {
        let diag = GlassesDiagnostics.shared
        let added: Camera?
        do { added = try session.addCamera(config: StreamConfiguration()) } catch {
            diag.record(.photo, "addCamera: \(error)")
            throw GlassesPhotoError.unsupported("addCamera: \(error)")
        }
        guard let camera = added else { throw GlassesPhotoError.unsupported("addCamera nil") }
        let photo = camera.photo
        let bag = ListenerTokenBag()
        let once = GlassesOnce<Result<Data, Error>>()
        let requested = GlassesFlag()
        let starting = GlassesFlag()
        let firstBytes = GlassesFlag()
        let started = Date()
        let ms: @Sendable () -> Int = { Int(Date().timeIntervalSince(started) * 1000) }
        var timers: [Task<Void, Never>] = []
        let result: Result<Data, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, Error>, Never>) in
                once.set { continuation.resume(returning: $0) }
                // Registrar TODO antes de start(): los publishers no re-emiten.
                photo.photoDataPublisher.listen { capture in
                    // El shutter físico publica en el mismo canal: solo vale tras pedirla.
                    if requested.isSet { once.fire(.success(capture.imageData)) }
                }.store(in: bag)
                photo.transferProgressPublisher.listen { progress in
                    if firstBytes.setOnce() { diag.record(.photo, "standalone transfiriendo (\(progress.totalBytes) bytes)") }
                }.store(in: bag)
                photo.errorPublisher.listen { error in
                    diag.record(.photo, "standalone error: \(error)")
                    once.fire(.failure(map(error)))
                }.store(in: bag)
                photo.statePublisher.listen { state in
                    diag.record(.photo, "standalone \(state) (\(ms()) ms)")
                    switch state {
                    case .starting:
                        starting.set()
                    case .started:
                        // `.started` puede repetirse: capturar solo en el primero, y
                        // fuera del callback del SDK (sample oficial: hop al main).
                        guard !once.isResolved, requested.setOnce() else { return }
                        Task { @MainActor in
                            guard !once.isResolved else { return }
                            photo.capturePhoto(resolution: photoResolution, quality: photoQuality)
                        }
                    case .stopped:
                        if !once.isResolved,
                           let failure = GlassesStandaloneStop.failure(starting: starting.isSet,
                                                                       requested: requested.isSet) {
                            once.fire(.failure(failure))
                        }
                    default:
                        break
                    }
                }.store(in: bag)
                photo.start()
                timers.append(Task {
                    try? await Task.sleep(nanoseconds: UInt64(photoStartTimeout * 1_000_000_000))
                    if !requested.isSet { once.fire(.failure(GlassesPhotoError.setupFailed("timeout"))) }
                })
                timers.append(Task {
                    try? await Task.sleep(nanoseconds: UInt64(photoTimeout * 1_000_000_000))
                    once.fire(.failure(GlassesPhotoError.timeout))
                })
            }
        } onCancel: {
            once.fire(.failure(CancellationError()))
        }
        timers.forEach { $0.cancel() }
        await bag.cancelAll()
        photo.stop()
        camera.stop()
        diag.record(.photo, "standalone teardown (\(ms()) ms)")
        return try result.get()
    }

    static func map(_ error: PhotoError) -> GlassesPhotoError {
        switch error {
        case .sessionSetupFailed: return .setupFailed(error.description)
        case .serviceUnavailable, .notReady: return .unsupported(error.description)
        case .permissionDenied: return .permissionDenied(error.description)
        case .busy: return .busy
        default: return .failed(error.description)
        }
    }

    /// El flujo PRE-1.0 (frame del stream): fallback de la standalone.
    @MainActor
    static func streamPhoto(_ session: DeviceSession) async throws -> Data {
        let diag = GlassesDiagnostics.shared
        let added: Camera?
        do { added = try session.addCamera(config: StreamConfiguration()) } catch {
            diag.record(.photo, "addCamera (stream): \(error)")
            throw GlassesPhotoError.unavailable("addCamera: \(error)")
        }
        guard let camera = added else { throw GlassesPhotoError.unavailable("addCamera nil (stream)") }
        let stream = camera.stream
        let bag = ListenerTokenBag()
        let once = GlassesOnce<Result<Data, Error>>()
        let requested = GlassesFlag()
        var timer: Task<Void, Never>?
        let requestCapture: @Sendable () -> Void = {
            guard !once.isResolved, requested.setOnce() else { return }
            Task { @MainActor in
                guard !once.isResolved else { return }
                _ = stream.capturePhoto(format: .jpeg)
            }
        }
        let result: Result<Data, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Data, Error>, Never>) in
                once.set { continuation.resume(returning: $0) }
                stream.photoDataPublisher.listen { photo in
                    if requested.isSet { once.fire(.success(photo.data)) }
                }.store(in: bag)
                stream.errorPublisher.listen { error in
                    diag.record(.photo, "stream error: \(error)")
                    once.fire(.failure(GlassesPhotoError.failed("\(error)")))
                }.store(in: bag)
                stream.statePublisher.listen { state in
                    diag.record(.photo, "stream \(state)")
                    if state == .streaming { requestCapture() }
                }.store(in: bag)
                stream.start()
                if stream.state == .streaming { requestCapture() }
                timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(streamTimeout * 1_000_000_000))
                    once.fire(.failure(GlassesPhotoError.timeout))
                }
            }
        } onCancel: {
            once.fire(.failure(CancellationError()))
        }
        timer?.cancel()
        await bag.cancelAll()
        stream.stop()
        camera.stop()
        diag.record(.photo, "stream teardown")
        return try result.get()
    }
    #endif
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
            return self.icon(icon, mode: HUDIconPolicy.mode)
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
        let mode = HUDIconPolicy.mode
        let button = Button(label: HUDIconPolicy.buttonLabel(b.label, icon: b.icon, mode: mode), style: buttonStyle(b.style),
                            iconName: HUDIconPolicy.buttonIcon(b.icon, mode: mode).map(iconName)) { onAction(action) }
        // DAT 1.0: el primer botón con rol primary recibe el foco al renderizar.
        return b.isPrimaryAction ? button.actionRole(.primary) : button
    }

    /// Un icono suelto por el camino de `HUDIconPolicy` (nativo / glifo propio /
    /// texto). Sin glifo renderizable cae a texto; nunca al sol.
    static func icon(_ node: HUDIconNode, mode: HUDIconMode) -> any ViewComponent {
        switch node.path ?? HUDIconPolicy.path(for: node.name, mode: mode) {
        case .native:
            return Icon(name: iconName(node.name), style: node.style == .filled ? .filled : .outline)
        case .image:
            if let symbol = HUDIconPolicy.symbol(for: node.name), let image = HUDGlyphImages.image(symbol: symbol) {
                return Image(image: image, sizePreset: .icon, cornerRadius: .none)
            }
            return textGlyph(node.name)
        case .text:
            return textGlyph(node.name)
        }
    }

    static func textGlyph(_ icon: HUDIcon) -> Text {
        Text(HUDIconPolicy.text(for: icon) ?? "•", style: .meta, color: .primary)
    }

    /// HUDIcon → IconName EXHAUSTIVO (116/116, sin rawValue ni fallback): si el SDK
    /// renombra o quita un glifo, esto deja de compilar en vez de pintar el sol.
    static func iconName(_ icon: HUDIcon) -> IconName {
        switch icon {
        case .airplane: return .airplane
        case .arrowDownShallowU: return .arrowDownShallowU
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .arrowULeft: return .arrowULeft
        case .arrowUpShallowU: return .arrowUpShallowU
        case .avatar: return .avatar
        case .avatarOff: return .avatarOff
        case .bedSide: return .bedSide
        case .bell: return .bell
        case .bellDiagonalRightDot: return .bellDiagonalRightDot
        case .bellOff: return .bellOff
        case .bikeShare: return .bikeShare
        case .bug: return .bug
        case .bullhorn: return .bullhorn
        case .bus: return .bus
        case .calendar: return .calendar
        case .campfire: return .campfire
        case .caretDown: return .caretDown
        case .caretLeft: return .caretLeft
        case .caretRight: return .caretRight
        case .caretUp: return .caretUp
        case .carFrontView: return .carFrontView
        case .cart: return .cart
        case .checkmark: return .checkmark
        case .checkmarkCircle: return .checkmarkCircle
        case .circle8RaysLarge: return .circle8RaysLarge
        case .circleHandle: return .circleHandle
        case .clock: return .clock
        case .cloud: return .cloud
        case .cloudCrescentMoon: return .cloudCrescentMoon
        case .cloudDotFourRays: return .cloudDotFourRays
        case .cloudFiveDashes: return .cloudFiveDashes
        case .cloudHookSwirl: return .cloudHookSwirl
        case .cloudLightning: return .cloudLightning
        case .cocktailGlass: return .cocktailGlass
        case .code: return .code
        case .coffeeCup: return .coffeeCup
        case .compassNorthUpRed: return .compassNorthUpRed
        case .containerWithLid: return .containerWithLid
        case .crossBriefcase: return .crossBriefcase
        case .dropper: return .dropper
        case .envelopeOpen: return .envelopeOpen
        case .exclamationCircle: return .exclamationCircle
        case .exclamationTriangle: return .exclamationTriangle
        case .eye: return .eye
        case .forkKnife: return .forkKnife
        case .fourArcsUpFilled: return .fourArcsUpFilled
        case .fourArcsUpGrayscale: return .fourArcsUpGrayscale
        case .fourCornerFrame: return .fourCornerFrame
        case .gear: return .gear
        case .globeWesternHemisphere: return .globeWesternHemisphere
        case .graduationCap: return .graduationCap
        case .hashtag: return .hashtag
        case .headphones: return .headphones
        case .heart: return .heart
        case .house: return .house
        case .iCircle: return .iCircle
        case .lightBulb: return .lightBulb
        case .magicWand: return .magicWand
        case .metaAi: return .metaAi
        case .mountainSquare: return .mountainSquare
        case .mountainSquareStacked: return .mountainSquareStacked
        case .museumBuilding: return .museumBuilding
        case .musicNote: return .musicNote
        case .nineSquaresGrid: return .nineSquaresGrid
        case .padlockClosed: return .padlockClosed
        case .padlockOpen: return .padlockOpen
        case .palette: return .palette
        case .paperAirplane: return .paperAirplane
        case .pencil: return .pencil
        case .pencilSquare: return .pencilSquare
        case .person: return .person
        case .personCircle: return .personCircle
        case .phone: return .phone
        case .phoneHandsetArrowDownLeft: return .phoneHandsetArrowDownLeft
        case .phoneHandsetArrowUpRight: return .phoneHandsetArrowUpRight
        case .phoneSlash: return .phoneSlash
        case .pizzaSlice: return .pizzaSlice
        case .plus: return .plus
        case .plusCircle: return .plusCircle
        case .shoppingBag: return .shoppingBag
        case .slidersHorizontal: return .slidersHorizontal
        case .smartGlasses: return .smartGlasses
        case .smileyCircle: return .smileyCircle
        case .speakerOff: return .speakerOff
        case .speakerWithOneArc: return .speakerWithOneArc
        case .speakerWithThreeArcs: return .speakerWithThreeArcs
        case .speakerWithTwoArcs: return .speakerWithTwoArcs
        case .speechBubble: return .speechBubble
        case .speechBubbleOff: return .speechBubbleOff
        case .stadium: return .stadium
        case .star: return .star
        case .starCircleTriangleAi: return .starCircleTriangleAi
        case .taxi: return .taxi
        case .threeDotsHorizontal: return .threeDotsHorizontal
        case .threeDotSpeechBubble: return .threeDotSpeechBubble
        case .threeHorizontalLines: return .threeHorizontalLines
        case .threeHorizontalLinesStackedDescending: return .threeHorizontalLinesStackedDescending
        case .threePeopleOverlapping: return .threePeopleOverlapping
        case .train: return .train
        case .tree: return .tree
        case .triangleLeftVerticalLine: return .triangleLeftVerticalLine
        case .triangleRight: return .triangleRight
        case .triangleRightCircle: return .triangleRightCircle
        case .triangleRightVerticalLine: return .triangleRightVerticalLine
        case .twoArrowsClockwise: return .twoArrowsClockwise
        case .twoLinesParallel: return .twoLinesParallel
        case .twoSquaresStackedRightDown: return .twoSquaresStackedRightDown
        case .twoTrianglesLeft: return .twoTrianglesLeft
        case .twoTrianglesRight: return .twoTrianglesRight
        case .videoCamera: return .videoCamera
        case .videoCameraOff: return .videoCameraOff
        case .wristband: return .wristband
        case .wristbandSlash: return .wristbandSlash
        case .x: return .x
        }
    }

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
