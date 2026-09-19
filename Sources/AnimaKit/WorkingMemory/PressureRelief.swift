// PressureRelief.swift — la escalera mecánico→inteligente del alivio de presión
// (§5.1, doc A: masking primero, −52% costo sin degradar). Función pura de
// (presión) → (controles de request); el server hace el trabajo.

import Foundation

/// Controles de gestión de contexto que viajan en el request. Ambos son
/// server-side (betas context-management-2025-06-27 y compact-2026-01-12):
/// cero llamadas propias del cliente.
public struct ReliefControls: Sendable, Equatable {
    /// context-management: `clear_tool_uses_20250919` limpia tool results viejos
    /// re-fetchables server-side.
    public var clearStaleToolResults: Bool
    /// compaction: la plataforma destila el contexto; el harness re-anexa los
    /// bloques compaction del response cada turno siguiente.
    public var compact: Bool

    public init(clearStaleToolResults: Bool = false, compact: Bool = false) {
        self.clearStaleToolResults = clearStaleToolResults
        self.compact = compact
    }

    public var isActive: Bool { clearStaleToolResults || compact }

    public func merged(with other: ReliefControls) -> ReliefControls {
        ReliefControls(
            clearStaleToolResults: clearStaleToolResults || other.clearStaleToolResults,
            compact: compact || other.compact)
    }
}

/// Identificadores de las ediciones de gestión de contexto (rotables vía Remote
/// Config junto con las betas — §4.8, pregunta abierta #7).
public enum ContextManagementEdit {
    public static let clearToolUses = "clear_tool_uses_20250919"
    public static let compact = "compact_20260112"
}

public enum PressureRelief {
    /// Umbrales del §5.1: >0.7 clear mecánico, >0.85 compaction server-side.
    public static let clearThreshold = 0.7
    public static let compactThreshold = 0.85

    /// Escalera: presión → controles de request.
    public static func plan(pressure: Double) -> ReliefControls {
        if pressure > compactThreshold {
            return ReliefControls(clearStaleToolResults: true, compact: true)
        }
        if pressure > clearThreshold {
            return ReliefControls(clearStaleToolResults: true)
        }
        return ReliefControls()
    }

    /// El bloque `context_management` del body para unos controles dados.
    /// `nil` si no hay nada que enviar.
    public static func contextManagementBody(_ controls: ReliefControls) -> JSONValue? {
        guard controls.isActive else { return nil }
        var edits: [JSONValue] = []
        if controls.clearStaleToolResults {
            edits.append(.object(["type": .string(ContextManagementEdit.clearToolUses)]))
        }
        if controls.compact {
            edits.append(.object(["type": .string(ContextManagementEdit.compact)]))
        }
        return .object(["edits": .array(edits)])
    }
}
