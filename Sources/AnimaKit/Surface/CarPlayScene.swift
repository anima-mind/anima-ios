// CarPlayScene.swift — lo testeable de la escena del carro (el delegate de
// App/CarPlay solo cablea CarPlay a esto):
//   · CarPlayStatePresenter: el template de voz IGNORA cambios de estado
//     "demasiado rápidos o frecuentes" (header de CPVoiceControlTemplate): se
//     espacian, se colapsan al último y se reconcilia la fase final;
//   · CarPlaySceneLifecycle: la base despierta solo con la escena al frente;
//     en background la voz se corta limpio (Apple: el template de voz a la vista
//     mientras hay voz) y el turno cierra con un background task; y el micrófono
//     no se abre solo cuando CarPlay restaura Anima al arrancar el carro.

import Foundation

/// Proyecta la fase de la conversación al template respetando su límite de
/// frecuencia: entre dos `apply` pasa al menos `minInterval`; si llegan varias
/// fases seguidas solo se aplica la última; y tras cada cambio se verifica
/// (`current`) que el template de verdad quedó en esa fase — si ignoró el
/// cambio, se re-aplica (hasta `maxRetries`).
@MainActor
public final class CarPlayStatePresenter {
    private let minInterval: Duration
    private let reconcileAfter: Duration
    private let maxRetries: Int
    private let apply: @MainActor (String) -> Void
    private let current: @MainActor () -> String?
    private let clock = ContinuousClock()

    private var desired: String?
    private var lastApply: ContinuousClock.Instant?
    private var scheduled: Task<Void, Never>?
    private var reconcile: Task<Void, Never>?

    public init(minInterval: Duration = .milliseconds(600), reconcileAfter: Duration = .milliseconds(800),
                maxRetries: Int = 4,
                apply: @escaping @MainActor (String) -> Void,
                current: @escaping @MainActor () -> String?) {
        self.minInterval = minInterval
        self.reconcileAfter = reconcileAfter
        self.maxRetries = maxRetries
        self.apply = apply
        self.current = current
    }

    /// La fase que se quiere ver (la última gana).
    public var target: String? { desired }

    public func show(_ phase: CarPlayPhase) {
        show(identifier: CarPlayTemplateModel.identifier(phase))
    }

    public func show(identifier: String) {
        desired = identifier
        guard scheduled == nil else { return }   // ya hay un apply en espera: aplicará la última
        let wait = lastApply.map { minInterval - (clock.now - $0) } ?? .zero
        if wait <= .zero {
            applyNow()
        } else {
            scheduled = Task { @MainActor [weak self] in
                try? await Task.sleep(for: wait)
                self?.fireScheduled()
            }
        }
    }

    public func stop() {
        scheduled?.cancel()
        scheduled = nil
        reconcile?.cancel()
        reconcile = nil
    }

    private func fireScheduled() {
        scheduled = nil
        applyNow()
    }

    private func applyNow() {
        guard let desired else { return }
        lastApply = clock.now
        apply(desired)
        scheduleReconcile(retries: maxRetries)
    }

    private func scheduleReconcile(retries: Int) {
        reconcile?.cancel()
        let delay = reconcileAfter
        reconcile = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reconcileNow(retries: retries)
        }
    }

    private func reconcileNow(retries: Int) {
        guard let desired, current() != desired, retries > 0, scheduled == nil else { return }
        lastApply = clock.now
        apply(desired)
        scheduleReconcile(retries: retries - 1)
    }
}

/// El ciclo de vida de la escena del carro, sin CarPlay: el delegate le avisa
/// conectar / activa / background / desconectar.
@MainActor
public final class CarPlaySceneLifecycle {
    /// Un trabajo que retiene la base y un background task de iOS hasta que el
    /// turno cortado termine de cerrar; devuelve con qué soltarlo.
    public typealias BackgroundWork = @MainActor () -> @MainActor () -> Void

    private let conversation: CarPlayConversation
    private let hold: @MainActor (Bool) -> Void
    private let backgroundWork: BackgroundWork
    private var holding = false
    private var connected = false
    /// La escena pasó a background desde que se conectó: volver a ella es que el
    /// conductor la ABRIÓ (tocó Anima en el carro), no una restauración.
    private var reopened = false

    public init(conversation: CarPlayConversation, hold: @escaping @MainActor (Bool) -> Void,
                backgroundWork: @escaping BackgroundWork) {
        self.conversation = conversation
        self.hold = hold
        self.backgroundWork = backgroundWork
    }

    public var holdsDatabase: Bool { holding }

    public func didConnect() {
        connected = true
        reopened = false
        setHold(true)
    }

    /// La escena quedó al frente en el carro. La PRIMERA activación tras
    /// conectar no abre el micrófono (CarPlay restaura la última app al
    /// arrancar el carro y la guía pide no activar el audio "at the time your
    /// app launches"); se espera a Hablar. Volver a Anima después (la abrió el
    /// conductor) sí escucha de una: voz primero.
    public func didBecomeActive() {
        guard connected else { return }
        setHold(true)
        if reopened {
            reopened = false
            conversation.talk()
        }
    }

    /// Otra app al frente en el carro: el template de voz ya no se ve, así que
    /// la voz se corta (escucha, confirmación, respuesta); el turno cierra en el
    /// chat con un background task que retiene la base solo mientras cierra. El
    /// hold de la escena se suelta YA.
    public func didEnterBackground() {
        guard connected else { return }
        reopened = true
        stopVoice { $0.cancel() }
        setHold(false)
    }

    public func didDisconnect() {
        connected = false
        reopened = false
        stopVoice { $0.disconnect() }
        setHold(false)
    }

    private func stopVoice(_ stop: (CarPlayConversation) -> Void) {
        guard conversation.isBusy else {
            stop(conversation)
            return
        }
        let end = backgroundWork()
        stop(conversation)
        let conversation = self.conversation
        Task { @MainActor in
            await conversation.waitUntilIdle()
            end()
        }
    }

    private func setHold(_ value: Bool) {
        guard value != holding else { return }
        holding = value
        hold(value)
    }
}
