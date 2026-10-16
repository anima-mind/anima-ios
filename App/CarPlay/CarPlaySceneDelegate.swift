// CarPlaySceneDelegate.swift — la escena de CarPlay (categoría "voice-based
// conversation", entitlement com.apple.developer.carplay-voice-based-conversation,
// iOS 26.4+). Capa humilde: proyecta CarPlayConversation (AnimaKit, testeada) a
// UN CPVoiceControlTemplate de 5 estados (reposo, escuchando, pensando,
// respondiendo, ¿lo hago?) con sus botones fijos, y le entrega los taps. El
// ciclo de vida (base, background, cuándo escuchar) y el ritmo de los cambios
// de estado viven en CarPlaySceneLifecycle / CarPlayStatePresenter (AnimaKit).
// Reglas de Apple: voz primero, nada de texto ni imágenes como respuesta, la
// sesión de audio solo mientras hay voz y con el template de voz a la vista,
// ≤3 templates de profundidad (aquí: 1).
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
    private var presenter: CarPlayStatePresenter?
    private var name = ""
    private lazy var lifecycle = CarPlaySceneLifecycle(
        conversation: conversation,
        hold: { hold in
            if hold { DatabaseSuspension.shared.begin() } else { DatabaseSuspension.shared.end() }
        },
        backgroundWork: {
            // El turno cortado cierra en el chat (escribe en la base): base
            // despierta + background task hasta que termine; si iOS expira el
            // tiempo, la base se suspende ya (0xdead10cc).
            DatabaseSuspension.shared.begin()
            let flush = BackgroundFlush.begin(onExpire: { DatabaseSuspension.shared.expire() })
            var ended = false
            return {
                guard !ended else { return }
                ended = true
                DatabaseSuspension.shared.end()
                flush.end()
            }
        })

    private var conversation: CarPlayConversation { AppModel.live.carPlayConversation() }

    // MARK: - Conexión

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.prefersDarkUserInterfaceStyle = true
        lifecycle.didConnect()
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
        lifecycle.didDisconnect()
        conversation.observe { _ in }
        presenter?.stop()
        presenter = nil
        self.interfaceController = nil
        voiceTemplate = nil
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        lifecycle.didBecomeActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        lifecycle.didEnterBackground()
    }

    // MARK: - Template

    /// La raíz se elige por disponibilidad, no por el completion: un template no
    /// soportado por la categoría lanza una excepción (guía, "Templates").
    private func install(name: String) {
        guard let interfaceController else { return }
        self.name = name
        guard #available(iOS 26.4, *) else {
            // La categoría y su entitlement existen desde iOS 26.4: antes, solo
            // se informa (sin micrófono ni voz).
            let item = CPInformationItem(title: CarPlayTemplateModel.displayName(name), detail: CarPlayTurn.needsNewerIOSText)
            let info = CPInformationTemplate(title: CarPlayTemplateModel.displayName(name), layout: .leading,
                                             items: [item], actions: [])
            interfaceController.setRootTemplate(info, animated: false, completion: nil)
            return
        }
        let template = CPVoiceControlTemplate(voiceControlStates: CarPlayTemplateModel.states(name: name).map(makeState))
        voiceTemplate = template
        presenter?.stop()
        let presenter = CarPlayStatePresenter(
            apply: { [weak template] identifier in template?.activateVoiceControlState(withIdentifier: identifier) },
            current: { [weak template] in template?.activeStateIdentifier })
        self.presenter = presenter
        interfaceController.setRootTemplate(template, animated: false) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.voiceTemplate === template else { return }
                self.conversation.observe { [weak presenter] phase in presenter?.show(phase) }
            }
        }
    }

    @available(iOS 26.4, *)
    private func makeState(_ state: CarPlayVoiceState) -> CPVoiceControlState {
        let voiceState = CPVoiceControlState(identifier: state.identifier, titleVariants: state.titleVariants,
                                             image: Self.image(state.symbol, size: 96), repeats: state.repeats)
        voiceState.actionButtons = state.buttons.prefix(CPVoiceControlState.maximumActionButtonCount).map { button in
            let action = CPButton(image: Self.image(button.symbol)) { @Sendable [weak self] _ in
                Task { @MainActor in self?.conversation.tapped(button) }
            }
            action.title = button.title
            return action
        }
        return voiceState
    }

    private static func image(_ symbol: String, size: CGFloat = 40) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
        return UIImage(systemName: symbol, withConfiguration: config) ?? UIImage()
    }
}
#endif
