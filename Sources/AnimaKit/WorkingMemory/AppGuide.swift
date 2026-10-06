// AppGuide.swift — el mapa de la app que ella conoce para guiar al dueño. Va en
// el system BASE de cada turno del chat (prefijo estable y cacheado; NO Remote
// Config, NO el bloque volátil). Fuente única: un test verifica que nombra cada
// tab y cada fila del hub de Ajustes por su nombre visible.

import Foundation

/// Las tabs del shell con su nombre visible (la tab bar y AppGuide leen de aquí).
public enum ShellTab: String, Hashable, CaseIterable, Sendable {
    case chat, memory, goals, approvals, settings

    public var title: String {
        switch self {
        case .chat: return "Chat"
        case .memory: return "Memoria"
        case .goals: return "Metas"
        case .approvals: return "Aprobaciones"
        case .settings: return "Ajustes"
        }
    }
}

public enum AppGuide {

    public static let block = """
        TU APP (para guiar al dueño). Tabs: Chat (aquí; tus recordatorios y check-ins llegan como \
        tarjetas), Memoria (lo que recuerdas de él; puede invalidar un recuerdo), Metas (arriba \
        Recordatorios: lo programado, con Hecho y Cancelar; abajo sus metas y su check-in), Aprobaciones \
        (cambios de tu identidad que esperan su ok) y Ajustes.
        Ajustes: Cuenta (Apple, opcional), Modelo y costos (Solo este teléfono = modelo de Apple, gratis y \
        sin red; un remoto como Claude con su key; Híbrido = conversas con el remoto y el sueño corre \
        gratis en el teléfono; abajo los costos), Skills ("Enséñame algo" crea una conversando), Gafas \
        (vincular sus gafas Meta), Mente (tus noches de consolidación: de noche ordenas lo vivido; \
        "Simular una noche") y Notificaciones (permiso, "Avisos de Anima", lista de lo programado).
        Tus recordatorios son tuyos y los entregas tú; la agenda y la app Recordatorios del iPhone son \
        otra cosa. Lo que toca su teléfono pide confirmación en pantalla.
        Si pregunta dónde ver o cambiar algo, guíalo con estos nombres exactos (p.ej. "Metas → \
        Recordatorios", "Ajustes → Notificaciones").
        """

    /// El system base del turno: el de Remote Config + el mapa de la app.
    public static func systemBase(_ base: String) -> String {
        base.isEmpty ? block : base + "\n\n" + block
    }
}
