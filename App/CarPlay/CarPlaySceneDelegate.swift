// CarPlaySceneDelegate.swift — la escena de CarPlay (categoría "voice-based
// conversation", entitlement com.apple.developer.carplay-voice-based-conversation,
// iOS 26.4+). Capa humilde: proyecta CarPlayConversation (AnimaKit, testeada) a
// UN CPVoiceControlTemplate de 5 estados (reposo, escuchando, pensando,
// respondiendo, ¿lo hago?) con sus botones fijos, y le entrega los taps.
// Reglas de Apple: voz primero al abrir (se escucha apenas el dueño abre Anima
// en el carro), nada de texto ni imágenes como respuesta, la sesión de audio
// solo mientras hay voz, ≤3 templates de profundidad (aquí: 1, o 1 + el de voz
// presentado si el sistema no lo acepta como raíz).
// Los callbacks de CarPlay (botones, completions) NO llegan garantizados en el
// main thread: van `@Sendable` y saltan al main actor (un closure aislado al
// main actor que CarPlay llama desde otra cola revienta con el chequeo de Swift 6).

#if canImport(CarPlay)
import CarPlay
import UIKit
import AnimaKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var voiceTemplate: CPVoiceControlTemplate?
    /// El template de voz no entró como raíz: va presentado sobre una grilla.
    private var presentsVoice = false
    private var presented = false
    private var name = ""
    /// Voz primero: al abrir Anima en el carro se escucha una vez.
    private var listensOnOpen = false
    private var holdsDatabase = false

    private var conversation: CarPlayConversation { AppModel.live.carPlayConversation() }

    // MARK: - Conexión

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.prefersDarkUserInterfaceStyle = true
        holdDatabase(true)
        listensOnOpen = true
        install(name: AppModel.live.carPlaySelfName)
        // El nombre del self llega al terminar el cableado (puede ser un arranque solo en el carro).
        Task {
            await AppModel.live.ensureBootstrapped()
            let current = AppModel.live.carPlaySelfName
            if current != name, conversation.phase == .idle { install(name: current) }
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        conversation.disconnect()
        conversation.observe { _ in }
        self.interfaceController = nil
        voiceTemplate = nil
        presented = false
        listensOnOpen = false
        holdDatabase(false)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        holdDatabase(true)
        guard listensOnOpen else { return }
        listensOnOpen = false
        conversation.talk()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Otra app al frente en el carro: la voz no sigue sola.
        if conversation.isBusy, conversation.phase == .listening || conversation.phase == .confirming {
            conversation.cancel()
        }
    }

    // MARK: - Template

    private func install(name: String) {
        guard let interfaceController else { return }
        self.name = name
        let template = CPVoiceControlTemplate(voiceControlStates: CarPlayTemplateModel.states(name: name).map(makeState))
        voiceTemplate = template
        interfaceController.setRootTemplate(template, animated: false) { @Sendable [weak self] ok, _ in
            Task { @MainActor in
                guard let self else { return }
                if ok {
                    self.presentsVoice = false
                    self.observe(template)
                } else {
                    self.installFallback(template)
                }
            }
        }
    }

    /// Si el sistema no acepta el template de voz como raíz: una grilla de un
    /// botón ("Hablar con …") y el de voz presentado mientras hay conversación.
    private func installFallback(_ template: CPVoiceControlTemplate) {
        guard let interfaceController else { return }
        presentsVoice = true
        let title = CarPlayTemplateModel.state(.idle, name: name).titleVariants
        let talk = CPGridButton(titleVariants: title, image: Self.image(CarPlayButton.talk.symbol)) { @Sendable [weak self] _ in
            Task { @MainActor in self?.conversation.talk() }
        }
        let grid = CPGridTemplate(title: CarPlayTemplateModel.displayName(name), gridButtons: [talk])
        interfaceController.setRootTemplate(grid, animated: false) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.observe(template) }
        }
    }

    private func observe(_ template: CPVoiceControlTemplate) {
        conversation.observe { [weak self] phase in
            self?.show(phase, on: template)
        }
    }

    private func show(_ phase: CarPlayPhase, on template: CPVoiceControlTemplate) {
        guard template === voiceTemplate, let interfaceController else { return }
        if presentsVoice {
            if phase == .idle {
                if presented {
                    presented = false
                    interfaceController.dismissTemplate(animated: true, completion: nil)
                }
                return
            }
            if !presented {
                presented = true
                interfaceController.presentTemplate(template, animated: true) { @Sendable [weak self] _, _ in
                    Task { @MainActor in
                        guard let self else { return }
                        template.activateVoiceControlState(withIdentifier: CarPlayTemplateModel.identifier(self.conversation.phase))
                    }
                }
                return
            }
        }
        template.activateVoiceControlState(withIdentifier: CarPlayTemplateModel.identifier(phase))
    }

    private func makeState(_ state: CarPlayVoiceState) -> CPVoiceControlState {
        let voiceState = CPVoiceControlState(identifier: state.identifier, titleVariants: state.titleVariants,
                                             image: Self.image(state.symbol, size: 96), repeats: state.repeats)
        if #available(iOS 26.4, *) {
            voiceState.actionButtons = state.buttons.prefix(CPVoiceControlState.maximumActionButtonCount).map { button in
                let action = CPButton(image: Self.image(button.symbol)) { @Sendable [weak self] _ in
                    Task { @MainActor in self?.conversation.tapped(button) }
                }
                action.title = button.title
                return action
            }
        }
        return voiceState
    }

    private static func image(_ symbol: String, size: CGFloat = 40) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
        return UIImage(systemName: symbol, withConfiguration: config) ?? UIImage()
    }

    // MARK: - Base despierta

    /// Con el teléfono bloqueado y Anima al frente en el carro, la escena del
    /// teléfono está en background: la base no se suspende mientras CarPlay esté.
    private func holdDatabase(_ hold: Bool) {
        guard hold != holdsDatabase else { return }
        holdsDatabase = hold
        if hold { DatabaseSuspension.shared.begin() } else { DatabaseSuspension.shared.end() }
    }
}
#endif
