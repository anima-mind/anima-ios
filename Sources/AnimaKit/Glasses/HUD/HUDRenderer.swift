// HUDRenderer.swift — función PURA `HUDScreen → HUDView` (doc 05 §4.1). Cero
// estado en las gafas: la vista se reconstruye entera desde la pantalla actual
// (nuevo contenido, wake del display, reconexión). Árboles calcados del handoff
// (Design/hud-projection.md): root FlexBox(column, 12, pad 16) + botón "Atrás"
// en toda vista no-raíz + card FlexBox(column, 10, pad 12, .card) con fila
// icono·meta, heading, body y ButtonGroup(end). Textos en español.

import Foundation

/// Las pantallas del HUD (la máquina de estados del handoff).
public enum HUDScreen: Sendable, Equatable {
    /// Raíz. G0: la card estática de bienvenida "anima 👋" con el estado corporal.
    case home(status: String?)
    /// Foto iniciada por el dueño con el botón "Foto" de la Home (sin confirmación).
    case capturing
    /// La foto espera el permiso de cámara: Meta AI está abierta en el teléfono.
    case cameraPermission
    /// Captura de voz activa. `viaPhone` = degradó al micrófono del teléfono.
    case listening(viaPhone: Bool)
    /// Transcript mostrado ANTES de enviarlo (regla del handoff).
    case heard(transcript: String)
    case thinking(question: String)
    /// La respuesta se está diciendo por los parlantes (A2DP).
    case speaking(HUDCard)
    /// La respuesta ya se dijo: la card queda (done).
    case answer(HUDCard)
    case declined(String)
    case attention(String)
    /// Un fallo del cuerpo con título propio (foto, micrófono): siempre visible.
    case trouble(heading: String, message: String)
    /// Confirmación de cámara con pinch EN las gafas (§8).
    case cameraConfirm(reason: String)
    /// Card proyectada por el agente (`glasses_show`), ya validada.
    case agentCard(HUDFlexBox)
    /// "Sigue en el teléfono".
    case handoff
}

public enum HUDRenderer {
    public static let welcomeHeading = "anima 👋"

    public static func render(_ screen: HUDScreen) -> HUDView {
        switch screen {
        case .home(let status):
            return HUDView(name: "home", root: root(back: false, [
                .flexBox(card(icon: .smartGlasses, meta: "Anima", heading: welcomeHeading,
                              body: status ?? "Tu mente, ahora también en tus gafas.",
                              group: HUDButtonGroup(alignment: .start, buttons: [
                                  HUDButton("Hablar", style: .primary, icon: .speechBubble, action: .talk),
                                  HUDButton("Foto", style: .secondary, icon: .videoCamera, action: .photo),
                              ]))),
            ]), isRoot: true)

        case .capturing:
            return HUDView(name: "capturing", root: root(back: true, [
                .flexBox(card(icon: .videoCamera, meta: "Cámara", heading: "Tomando la foto…",
                              body: "Mantén la mirada en lo que quieres mostrar.", bodySecondary: true,
                              group: HUDButtonGroup(alignment: .end, buttons: [
                                  HUDButton("Cancelar", style: .outline, icon: .x, action: .cancel),
                              ]))),
            ]))

        case .cameraPermission:
            return HUDView(name: "cameraPermission", root: root(back: true, [
                .flexBox(card(icon: .videoCamera, meta: "Permiso de cámara", heading: HUDPhoto.permissionHeading,
                              body: "La foto se toma en cuanto vuelvas a Anima.", bodySecondary: true,
                              group: HUDButtonGroup(alignment: .end, buttons: [
                                  HUDButton("Cancelar", style: .outline, icon: .x, action: .cancel),
                              ]))),
            ]))

        case .listening(let viaPhone):
            return HUDView(name: "listening", root: root(back: true, [
                .flexBox(card(icon: .speechBubble,
                              meta: viaPhone ? "Escuchando (teléfono)… pausa para enviar"
                                             : "Escuchando (gafas)… pausa para enviar",
                              body: "Dilo. Anima responde en voz alta y te muestra lo esencial aquí.",
                              bodySecondary: true,
                              group: HUDButtonGroup(alignment: .end, buttons: [
                                  HUDButton("Cancelar", style: .outline, icon: .x, action: .cancel),
                              ]))),
            ]))

        case .heard(let transcript):
            return HUDView(name: "heard", root: root(back: true, [
                .flexBox(card(icon: .speechBubble, meta: "Te escuché",
                              body: "“" + HUDSummary.clip(transcript, HUDValidator.bodyLimit - 2) + "”",
                              group: HUDButtonGroup(alignment: .end, buttons: [
                                  HUDButton("Otra vez", style: .outline, icon: .twoArrowsClockwise, action: .again),
                                  HUDButton("Enviar", style: .primary, icon: .paperAirplane, action: .send,
                                            isPrimaryAction: true),
                              ]))),
            ]))

        case .thinking(let question):
            return HUDView(name: "thinking", root: root(back: true, [
                .flexBox(card(icon: .circle8RaysLarge, meta: "pensando…",
                              body: "“" + HUDSummary.clip(question, HUDValidator.bodyLimit - 2) + "”",
                              bodySecondary: true,
                              group: HUDButtonGroup(alignment: .end, buttons: [
                                  HUDButton("Cancelar", style: .outline, icon: .x, action: .cancel),
                              ]))),
            ]))

        case .speaking(let reply):
            return replyView(name: "speaking", icon: .speakerWithTwoArcs, meta: "Hablando", reply)

        case .answer(let reply):
            return replyView(name: "answer", icon: .speechBubble, meta: "Respuesta", reply)

        case .declined(let text):
            let gist = HUDSummary.card(from: text)
            return HUDView(name: "declined", root: root(back: true, [
                .flexBox(card(icon: .speechBubbleOff, meta: "Rechazado", heading: gist.heading,
                              body: gist.body.isEmpty ? nil : gist.body, group: nil)),
            ]))

        case .attention(let message):
            return HUDView(name: "attention", root: root(back: true, [
                .flexBox(card(icon: .exclamationTriangle, meta: "Atención", heading: "No pude responder.",
                              body: HUDSummary.clip(message, HUDValidator.bodyLimit), group: nil)),
            ]))

        case .trouble(let heading, let message):
            return HUDView(name: "trouble", root: root(back: true, [
                .flexBox(card(icon: .exclamationTriangle, meta: "Atención", heading: heading,
                              body: HUDSummary.clip(message, HUDValidator.bodyLimit), group: nil)),
            ]))

        case .cameraConfirm(let reason):
            return HUDView(name: "cameraConfirm", root: root(back: true, [
                .flexBox(card(icon: .videoCamera, meta: "Cámara · tu permiso", heading: "¿Tomo una foto?",
                              body: HUDSummary.clip(reason, HUDValidator.bodyLimit),
                              group: HUDButtonGroup(alignment: .end, buttons: [
                                  HUDButton("No", style: .outline, icon: .x, action: .cameraDeny),
                                  HUDButton("Tomar foto", style: .primary, icon: .checkmarkCircle, action: .cameraAllow,
                                            isPrimaryAction: true),
                              ]))),
            ]))

        case .agentCard(let box):
            return HUDView(name: "agentCard", root: root(back: true, [.flexBox(box)]))

        case .handoff:
            // Su único botón es la salida: el foco cae ahí (actionRole primary).
            return HUDView(name: "handoff", root: root(back: true, backIsPrimary: true, [
                .flexBox(card(icon: .phone, meta: "En el teléfono", heading: "Sigue en el teléfono.",
                              body: "Toca la notificación: la conversación está ahí, intacta.", group: nil)),
            ]))
        }
    }

    // MARK: - Piezas del design system (§4.1)

    static func replyView(name: String, icon: HUDIcon, meta: String, _ reply: HUDCard) -> HUDView {
        HUDView(name: name, root: root(back: true, [
            .flexBox(card(icon: icon, meta: meta, heading: reply.heading,
                          body: reply.body.isEmpty ? nil : reply.body,
                          group: HUDButtonGroup(alignment: .end, buttons: [
                              HUDButton("Responder", style: .primary, icon: .speechBubble, action: .reply,
                                        isPrimaryAction: true),
                              HUDButton("En el teléfono", style: .secondary, icon: .phone, action: .onPhone),
                          ]))),
        ]))
    }

    /// Root de toda vista: FlexBox(column, spacing 12, padding 16) [+ Atrás].
    static func root(back: Bool, backIsPrimary: Bool = false, _ children: [HUDNode]) -> HUDFlexBox {
        var nodes: [HUDNode] = []
        if back {
            nodes.append(.button(HUDButton("Atrás", style: .outline, icon: .arrowLeft, action: .back,
                                           isPrimaryAction: backIsPrimary)))
        }
        nodes.append(contentsOf: children)
        return HUDFlexBox(direction: .column, spacing: 12, padding: 16, children: nodes)
    }

    /// CardView: FlexBox(column, 10, pad 12, .card) [row(icon, meta) · heading · body · group].
    static func card(icon: HUDIcon, meta: String, heading: String? = nil, body: String? = nil,
                     bodySecondary: Bool = false, group: HUDButtonGroup?) -> HUDFlexBox {
        var nodes: [HUDNode] = [
            .flexBox(HUDFlexBox(direction: .row, spacing: 8, crossAlignment: .center, children: [
                .icon(HUDIconNode(icon, style: .outline)),
                .text(HUDText(meta, style: .meta, color: .secondary)),
            ])),
        ]
        if let heading, !heading.isEmpty {
            nodes.append(.text(HUDText(HUDSummary.clip(heading, HUDValidator.headingLimit), style: .heading)))
        }
        if let body, !body.isEmpty {
            nodes.append(.text(HUDText(body, style: .body, color: bodySecondary ? .secondary : .primary)))
        }
        if let group { nodes.append(.buttonGroup(group)) }
        return HUDFlexBox(direction: .column, spacing: 10, padding: 12, background: .card, children: nodes)
    }
}
