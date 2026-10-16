// PermissionPolicy.swift — capa 1 de los permisos 2-capas (§5.7, §8).
//
// Capa 1 (aquí): política del harness, ANTES de ejecutar, sobre la naturaleza de
// la acción. FAIL-CLOSED: lo no reconocido pide aprobación / se niega.
//   afferent  → allow (una vez concedido el permiso iOS de capa 2)
//   efferent  → ask por default; allowlist granular por (tool, operación)
//   tool desconocida / kind indeterminado → deny
//
// Capa 2 (el OS): TCC / entitlements de iOS. La app NO puede tocar lo no
// autorizado aunque la capa 1 falle. Esa capa vive en los frameworks de Apple
// dentro de cada tool (#if canImport), no aquí.

import Foundation

/// Naturaleza de una invocación de tool. Aferente = percibe (lee); eferente =
/// actúa sobre el mundo (crea/modifica/borra).
public enum ToolKind: Sendable, Equatable {
    case afferent
    case efferent
}

/// Decisión de la capa 1.
public enum PermissionDecision: Sendable, Equatable {
    case allow
    case ask     // confirmación in-chat con el diff de la acción
    case deny    // fail-closed
}

/// Una entrada de allowlist granular pre-aprobada por el dueño: (tool, operación).
/// v1 nace vacía — todo eferente pide `ask` (los eferentes destructivos JAMÁS
/// entran a la allowlist, §5.7).
public struct AllowlistEntry: Sendable, Equatable, Hashable {
    public var tool: String
    public var operation: String
    public init(tool: String, operation: String) {
        self.tool = tool
        self.operation = operation
    }
}

public struct PermissionPolicy: Sendable {
    private let allowlist: Set<AllowlistEntry>
    /// Lo que el dueño autorizó "siempre" (persistido; se revoca en Ajustes).
    private let ownerAllowlist: @Sendable () -> Set<AllowlistEntry>

    public init(allowlist: Set<AllowlistEntry> = [],
                ownerAllowlist: @escaping @Sendable () -> Set<AllowlistEntry> = { [] }) {
        self.allowlist = allowlist
        self.ownerAllowlist = ownerAllowlist
    }

    /// Batch 5b #1: escrituras SOLO en el estado propio de Anima y reversibles
    /// desde la app (Metas, Recordatorios) → sin sheet. Lo que toca el mundo
    /// (agenda, Recordatorios del iPhone, cámara…) sigue pidiendo ok.
    public static let internalReversible: Set<AllowlistEntry> = Set(
        ["declare", "set_checkin", "clear_checkin", "mark_achieved", "abandon", "replace"]
            .map { AllowlistEntry(tool: "goals", operation: $0) }
        + ["create", "complete", "cancel", "snooze", "reschedule", "reopen"].map { AllowlistEntry(tool: "anima_reminders", operation: $0) })

    /// Operaciones que destruyen algo FUERA del estado reversible de Anima
    /// (borrar un evento del calendario…). Jamás se autorizan "siempre": piden
    /// ok cada vez, y desde Siri o CarPlay se niegan.
    public static let destructiveOperations: Set<String> = ["delete", "remove", "erase", "purge", "clear"]

    /// ¿Destruye algo que el dueño no recupera desde Anima? Lo interno y
    /// reversible (cancelar un recordatorio de Anima, quitar un check-in) no.
    public static func isDestructive(tool: String, operation: String) -> Bool {
        let entry = AllowlistEntry(tool: tool, operation: operation)
        return !internalReversible.contains(entry) && destructiveOperations.contains(operation)
    }

    /// Internas reversibles que igual se hacen SOLO desde el teléfono: dejar o
    /// cambiar una meta no se ejecuta desde CarPlay ni Siri (se niega y queda
    /// pendiente en el teléfono, como lo riesgoso).
    public static let phoneOnly: Set<AllowlistEntry> = Set(
        ["abandon", "replace"].map { AllowlistEntry(tool: "goals", operation: $0) })

    /// La política de la app: internas reversibles + lo autorizado siempre.
    public static func app(ownerAllowlist: @escaping @Sendable () -> Set<AllowlistEntry>) -> PermissionPolicy {
        PermissionPolicy(allowlist: internalReversible, ownerAllowlist: ownerAllowlist)
    }

    /// Decide sobre una acción. `known` = la tool está registrada en el
    /// Sensorimotor; `operation` permite allowlisting granular de eferentes.
    public func decide(tool: String, known: Bool, kind: ToolKind, operation: String?) -> PermissionDecision {
        guard known else { return .deny }   // fail-closed: tool desconocida
        switch kind {
        case .afferent:
            return .allow
        case .efferent:
            if let operation {
                let entry = AllowlistEntry(tool: tool, operation: operation)
                if allowlist.contains(entry) { return .allow }
                // "Autorizar siempre" jamás cubre un borrado (aunque venga de un
                // build viejo que lo guardó): pide ok cada vez.
                if ownerAllowlist().contains(entry), !Self.isDestructive(tool: tool, operation: operation) {
                    return .allow
                }
            }
            return .ask
        }
    }
}

// MARK: - Confirmación in-chat (el `ask`)

/// Lo que el dueño confirma o rechaza: un diff legible de la acción eferente.
public struct ConfirmationRequest: Sendable, Equatable {
    public var tool: String
    public var operation: String
    public var summary: String   // "crear evento 'X' mañana 9:00"
    public var input: JSONValue
    /// Superficie del turno que la pidió: cada una confirma las suyas (Siri
    /// jamás resuelve una del chat o de las gafas).
    public var surface: SurfaceID

    public init(tool: String, operation: String, summary: String, input: JSONValue,
                surface: SurfaceID = .phoneChat) {
        self.tool = tool
        self.operation = operation
        self.summary = summary
        self.input = input
        self.surface = surface
    }
}

/// Provee la confirmación in-chat (sheet). El app shell la implementa contra la
/// UI; los tests inyectan una versión determinista.
public protocol ConfirmationProvider: Sendable {
    func confirm(_ request: ConfirmationRequest) async -> Bool
    /// La política de la superficie la negó SIN preguntar (cámara de las gafas
    /// desde Siri, acciones de riesgo desde CarPlay): quien lleva la cuenta de
    /// lo que quedó pendiente se entera aquí. Por defecto, nada.
    func refused(_ request: ConfirmationRequest) async
}

extension ConfirmationProvider {
    public func refused(_ request: ConfirmationRequest) async {}
}

/// Default FAIL-CLOSED: sin UI conectada, todo `ask` se niega. La app inyecta la
/// implementación real; los tests inyectan un aprobador/spy.
public struct FailClosedConfirmation: ConfirmationProvider {
    public init() {}
    public func confirm(_ request: ConfirmationRequest) async -> Bool { false }
}
