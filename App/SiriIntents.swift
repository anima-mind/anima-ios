// SiriIntents.swift — hablar con Anima sin abrir el teléfono (batch 10 #2).
// "Habla con Anima" / "Pregúntale a Anima": Siri pide el mensaje, el turno corre
// EN el proceso de la app (lanzada en background, sin UI) sobre el mismo loop y
// la misma sesión que el chat, y Siri dice la respuesta. Datos personales:
// `.requiresLocalDeviceAuthentication` (con el teléfono bloqueado basta un
// vistazo de Face ID; no hay que abrir nada). El turno queda en el chat con el
// chip "Siri". "Abre Anima con el micrófono" sigue siendo TalkToAnimaIntent.

import AppIntents
import AnimaKit

struct AskAnimaIntent: AppIntent {
    static let title: LocalizedStringResource = "Preguntarle a Anima"
    static let description = IntentDescription(
        "Habla con Anima sin abrir la app: Siri te dice su respuesta y la conversación queda en el chat.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Mensaje", requestValueDialog: IntentDialog("¿Qué le quieres decir a Anima?"))
    var message: String

    init() {}

    init(message: String) {
        self.message = message
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let spoken = await AppModel.live.askFromSiri(message) { summary in
            do {
                try await requestConfirmation(actionName: .go,
                                              dialog: IntentDialog(stringLiteral: SiriTurn.confirmationPrompt(summary)))
                return true
            } catch {
                return false
            }
        }
        return .result(value: spoken, dialog: IntentDialog(stringLiteral: spoken))
    }
}

/// Siri, Spotlight, Atajos y el botón de Acción. Frases en español (región de
/// desarrollo `es`); toda frase lleva el nombre de la app.
struct AnimaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAnimaIntent(),
            phrases: [
                "Habla con \(.applicationName)",
                "Pregúntale a \(.applicationName)",
                "Dile a \(.applicationName)",
                "Pregunta a \(.applicationName)",
                "Oye \(.applicationName)",
            ],
            shortTitle: "Pregúntale a Anima",
            systemImageName: "waveform")
        AppShortcut(
            intent: TalkToAnimaIntent(),
            phrases: [
                "Abre \(.applicationName) con el micrófono",
                "Háblale a \(.applicationName) en el chat",
                "Abre el chat de \(.applicationName)",
            ],
            shortTitle: "Hablar con Anima",
            systemImageName: "mic")
    }

    static let shortcutTileColor: ShortcutTileColor = .grayBlue
}
