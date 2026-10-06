// AppGuide.swift — el mapa de la app que ella conoce para guiar al dueño. Va en
// el system BASE de cada turno del chat (prefijo estable y cacheado; NO Remote
// Config, NO el bloque volátil). Fuente única: un test verifica que nombra cada
// tab y cada fila del hub de Ajustes por su nombre visible.

import Foundation

/// Las tabs del shell con su nombre visible (la tab bar y AppGuide leen de aquí).
public enum ShellTab: String, Hashable, CaseIterable, Sendable {
    case chat, memory, goals, reminders, settings

    public var title: String {
        switch self {
        case .chat: return "Chat"
        case .memory: return "Memoria"
        case .goals: return "Metas"
        case .reminders: return "Recordatorios"
        case .settings: return "Ajustes"
        }
    }
}

public enum AppGuide {

    public static let block = """
        TU APP (para guiar al dueño). Tabs: Chat (aquí; tus recordatorios y check-ins llegan como \
        tarjetas), Memoria (lo que recuerdas de él; puede invalidar un recuerdo), Metas (sus metas y el \
        check-in de cada una: cadencia y hora), Recordatorios (lo que tienes programado: qué le dirás, \
        cuándo, si se repite; desliza para Hecho o Cancelar; abajo los check-ins activos) y Ajustes.
        Ajustes: Cuenta (Apple, opcional), Modelo y costos (Solo este teléfono = modelo de Apple, gratis y \
        sin red; un remoto como Claude con su key; Híbrido = conversas con el remoto y el sueño corre \
        gratis en el teléfono; abajo los costos), Skills ("Enséñame algo" crea una conversando), Gafas \
        (vincular sus gafas Meta), Mente (tus noches de consolidación: de noche ordenas lo vivido; \
        "Simular una noche"; y "Por aprobar": cambios de tu identidad y metas que infieres esperan su ok) \
        y Notificaciones (permiso, "Avisos de Anima"). Si hay algo por aprobar, Ajustes lleva un número.
        Tus recordatorios son tuyos y los entregas tú; la agenda y la app Recordatorios del iPhone son \
        otra cosa. Lo que toca su teléfono pide confirmación en pantalla.
        Si pregunta dónde ver o cambiar algo, guíalo con estos nombres exactos (p.ej. "la tab \
        Recordatorios", "Ajustes → Mente → Por aprobar").
        """

    /// El system base del turno: el de Remote Config + el mapa de la app.
    public static func systemBase(_ base: String) -> String {
        base.isEmpty ? block : base + "\n\n" + block
    }
}
