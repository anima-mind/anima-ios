// VoiceInvocationsController.swift — adapter HUMILDE de "Hey Meta, start Anima"
// sobre `VoiceInvocationsStream` (MWDATCore 1.0.0, experimental). Calcado del
// patrón oficial (doc DAT "Voice invocations", iOS):
//   · `Wearables.configure()` antes del init del stream (si no:
//     invalidWearablesInterface);
//   · UN stream por device: `start(deviceIdentifier:)` de nuevo hace tear down
//     del anterior, así que cada device tiene el suyo;
//   · stream + AMBOS listener tokens como stored properties (fuera de scope se
//     sueltan las suscripciones); listeners registrados ANTES de `start`;
//   · cubre `wearables.devices` + `devicesStream()` y re-intenta al conectar
//     (link listener): `start` exige canal conectado.
// La lógica (qué hacer con LaunchApp, ACK exactamente una vez, cold-launch)
// vive en VoiceInvocationOrchestrator (AnimaKit, testeada). Verificable SOLO con
// gafas + permiso Voice Invocation aprobado en el portal de Meta.

#if canImport(MWDATCore)
import Foundation
import AnimaKit
import MWDATCore

@MainActor
final class VoiceInvocationsController: VoiceInvocationsPort {
    private struct Listener {
        let stream: VoiceInvocationsStream
        let invocationToken: any AnyListenerToken
        let errorToken: any AnyListenerToken
    }

    private var listeners: [DeviceIdentifier: Listener] = [:]
    private var linkTokens = ListenerTokenBag()
    private var watched: Set<DeviceIdentifier> = []
    private var devicesTask: Task<Void, Never>?
    private var handler: (@MainActor (VoiceInvocationsPortEvent) -> Void)?
    private var wearables: (any WearablesInterface)?

    func start(_ handler: @escaping @MainActor (VoiceInvocationsPortEvent) -> Void) {
        guard devicesTask == nil else { return }
        self.handler = handler
        do {
            try Wearables.configure()
        } catch WearablesError.alreadyConfigured {
            // idempotente (GlassesBody también configura)
        } catch {
            handler(.failure(.notPermitted))
            return
        }
        let wearables = Wearables.shared
        self.wearables = wearables
        sync(wearables.devices)
        devicesTask = Task { [weak self] in
            for await ids in wearables.devicesStream() { self?.sync(ids) }
        }
    }

    func stop() {
        devicesTask?.cancel()
        devicesTask = nil
        for id in Array(listeners.keys) { detach(id) }
        let bag = linkTokens
        Task { await bag.cancelAll() }
        linkTokens = ListenerTokenBag()
        watched = []
    }

    // MARK: - Devices

    private func sync(_ ids: [DeviceIdentifier]) {
        guard let wearables else { return }
        let current = Set(ids)
        for gone in listeners.keys where !current.contains(gone) { detach(gone) }
        for id in ids {
            guard let device = wearables.deviceForIdentifier(id) else { continue }
            if !watched.contains(id) {
                watched.insert(id)
                device.addLinkStateListener { [weak self] state in
                    Task { @MainActor in self?.linkChanged(id, state) }
                }.store(in: linkTokens)
            }
            if device.linkState == .connected { attach(id) }
        }
        handler?(.listening(deviceIds: Array(listeners.keys)))
    }

    private func linkChanged(_ id: DeviceIdentifier, _ state: LinkState) {
        switch state {
        case .connected: attach(id)
        case .disconnected: detach(id)
        case .connecting: return
        }
        handler?(.listening(deviceIds: Array(listeners.keys)))
    }

    private func attach(_ id: DeviceIdentifier) {
        guard listeners[id] == nil, let wearables else { return }
        do {
            let stream = try VoiceInvocationsStream(wearables: wearables)
            let invocationToken = stream.invocationsPublisher.listen { [weak self] invocation in
                Task { @MainActor in self?.deliver(invocation, from: id) }
            }
            let errorToken = stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in self?.handler?(.failure(Self.map(error))) }
            }
            do {
                try stream.start(deviceIdentifier: id)
            } catch {
                Task { await invocationToken.cancel(); await errorToken.cancel() }
                throw error
            }
            listeners[id] = Listener(stream: stream, invocationToken: invocationToken, errorToken: errorToken)
        } catch let error as VoiceInvocationError {
            handler?(.failure(Self.map(error)))
        } catch {
            handler?(.failure(.other("\(error)")))
        }
    }

    private func detach(_ id: DeviceIdentifier) {
        guard let listener = listeners.removeValue(forKey: id) else { return }
        listener.stream.stop()
        Task { await listener.invocationToken.cancel(); await listener.errorToken.cancel() }
    }

    private func deliver(_ invocation: any VoiceInvocation, from id: DeviceIdentifier) {
        let request: VoiceInvocationRequest
        if let launch = invocation as? LaunchApp {
            request = VoiceInvocationRequest(kind: .launchApp, deviceId: launch.deviceIdentifier,
                                             responder: DATResponder(handle: launch.responseHandle))
        } else {
            // VoiceInvocation no expone handle genérico: no hay cómo responderla.
            request = VoiceInvocationRequest(kind: .unsupported, deviceId: id, responder: NoResponder())
        }
        handler?(.invocation(request))
    }

    static func map(_ error: VoiceInvocationError) -> VoiceInvocationsFailure {
        switch error {
        case .invalidWearablesInterface, .initRequestError, .failToSendInitRequest:
            return .notPermitted
        case .deviceNotFound, .channelNotConnected:
            return .deviceUnavailable
        default:
            return .other(error.description)
        }
    }
}

/// El `ResponseHandle` del SDK (rechaza duplicados: responder dos veces es inocuo).
struct DATResponder: VoiceInvocationResponder {
    let handle: any ResponseHandle
    func respond(success: Bool, output: String?) async -> Bool {
        success ? await handle.sendSuccess(actionOutput: output) : await handle.sendFailure(actionOutput: output)
    }
}

struct NoResponder: VoiceInvocationResponder {
    func respond(success: Bool, output: String?) async -> Bool { false }
}
#endif
