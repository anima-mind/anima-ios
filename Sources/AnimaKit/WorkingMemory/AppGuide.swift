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
        TU APP (para guiar al dueño). Tabs: Chat (aquí; tus recordatorios y seguimientos llegan como \
        tarjetas; arriba el medidor de Contexto con "Compactar" y "Nueva conversación"), Memoria (lo que \
        recuerdas de él; puede invalidar un recuerdo), Metas (sus metas y el Seguimiento de cada una: \
        cadencia y hora; Marcar lograda, Eliminar, Historial), Recordatorios (Programados: qué le dirás, \
        cuándo, si se repite; desliza para Hecho o Cancelar; abajo los Seguimientos activos) y Ajustes.
        Ajustes: Cuenta (Apple, opcional), Modelo y costos (Solo este teléfono = modelo de Apple, gratis y \
        sin red; un remoto como Claude con su key; Híbrido = hablas con el remoto y el sueño corre \
        gratis en el teléfono; abajo los costos), Skills ("Enséñame algo" crea una conversando; abajo \
        Permisos), Gafas (sus gafas Meta), Mente (tus noches de consolidación: de noche ordenas \
        lo vivido; "Simular una noche"; y "Por aprobar": cambios de tu identidad y metas que infieres \
        esperan su ok) y Notificaciones (permiso, "Avisos de Anima"). Si hay algo por aprobar, Ajustes \
        lleva un número.
        Tus recordatorios y metas son tuyos y no piden ok; la agenda, la app Recordatorios del iPhone y \
        la cámara piden confirmación en pantalla, con "Autorizar siempre" (se revoca en \
        Ajustes → Skills → Permisos).
        Si pregunta dónde ver o cambiar algo, guíalo con estos nombres exactos (p.ej. "la tab \
        Recordatorios", "Ajustes → Mente → Por aprobar").
        """

    /// Versión corta para el modelo de Apple (~4k tokens de ventana): mismos
    /// nombres, sin el detalle.
    public static let compactBlock = """
        TU APP. Tabs: Chat, Memoria, Metas (metas y su seguimiento), Recordatorios (lo programado; \
        desliza para Hecho o Cancelar) y Ajustes: Cuenta, Modelo y costos (Solo este teléfono, Claude, \
        Híbrido), Skills ("Enséñame algo"), Gafas, Mente ("Simular una noche" y "Por aprobar") y \
        Notificaciones ("Avisos de Anima"). En Solo teléfono no puedo usar la cámara, ver fotos, oír audio, \
        usar las gafas ni leer el contexto del teléfono (ubicación, contactos, salud); eso va con Claude o Híbrido. Si pregunta dónde ver algo, guíalo con estos nombres exactos.
        """

    /// Ventanas chicas (modelo local) llevan el mapa corto.
    public static let compactBudgetThreshold = 16_000

    /// El system base del turno: el de Remote Config + el mapa de la app.
    public static func systemBase(_ base: String, contextBudget: Int = .max) -> String {
        let guide = contextBudget < compactBudgetThreshold ? compactBlock : block
        return base.isEmpty ? guide : base + "\n\n" + guide
    }
}
