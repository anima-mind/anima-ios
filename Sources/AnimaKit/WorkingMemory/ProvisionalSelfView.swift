// ProvisionalSelfView.swift — el SelfView ESTÁTICO provisional de Fase 1 (§6).
// Renderiza el bloque mid-conversation system del canal de autoridad (§4.5).
// Fase 3 lo reemplaza por el render vivo del SelfModel (plasticidad + regímenes).

import Foundation

public struct ProvisionalSelfView: Sendable, Equatable {
    public var name: String
    public var tone: String
    public var language: String

    public init(name: String, tone: String, language: String) {
        self.name = name
        self.tone = tone
        self.language = language
    }

    /// Seed mínimo de Fase 1 (pregunta abierta #8: seed manual + bootstrap libre).
    public static let provisional = ProvisionalSelfView(
        name: "Anima",
        tone: "cercano, directo y honesto",
        language: "español (es-CO)")

    /// Bloque corto para el mensaje `{"role":"system"}` dentro de messages[].
    /// Determinístico: es la base del golden test del orden de ensamblado.
    public func render() -> String {
        """
        [SELF] Eres \(name). Tono: \(tone). Idioma por defecto: \(language). \
        Identidad provisional (Fase 1, estática); madura por consolidación en fases posteriores.
        """
    }
}
