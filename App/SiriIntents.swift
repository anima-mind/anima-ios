// SiriIntents.swift — hablar con Anima sin abrir el teléfono (batch 10 #2).
// "Pregúntale a Anima" / "Consulta a Anima": Siri pide el mensaje, el turno corre
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
        "Habla con Anima sin abrir la app: te responde en voz y la conversación queda en el chat.")
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
/// desarrollo `es`) y traducidas por locale en App/AppShortcuts.xcstrings (es,
/// es-419, es-MX, es-US, es-ES, en): el iPhone del dueño tiene el asistente en
/// una variante regional. Toda frase lleva el nombre de la app.
/// Campo build 27: "Habla con …" y "Dile a …" son de los dominios del sistema
/// (llamadas / mensajes: el asistente intentaba llamar o abrir WhatsApp) y
/// "Oye …" es la palabra de activación: fuera.
struct AnimaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAnimaIntent(),
            phrases: [
                "Pregúntale a \(.applicationName)",
                "Pregunta a \(.applicationName)",
                "Consulta a \(.applicationName)",
                "Hazle una pregunta a \(.applicationName)",
                "\(.applicationName), tengo una pregunta",
            ],
            shortTitle: "Pregúntale a Anima",
            systemImageName: "waveform")
        AppShortcut(
            intent: TalkToAnimaIntent(),
            phrases: [
                "Abre \(.applicationName) con el micrófono",
                "Abre el micrófono de \(.applicationName)",
                "Abre el chat de \(.applicationName)",
            ],
            shortTitle: "Hablar con Anima",
            systemImageName: "mic")
    }

    static let shortcutTileColor: ShortcutTileColor = .grayBlue
}
