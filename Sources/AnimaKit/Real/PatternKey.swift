// PatternKey.swift — la normalización de un fallo a clave estable (§5.6). La
// igualdad del patrón es igualdad de hash: se descartan los valores volátiles
// (paths → dirname, IDs/UUIDs → <id>, fechas → <date>, strings libres → <text>,
// números → <n>) para que "la misma estrategia que falla" colapse a una clave.

import Foundation
import CryptoKit

public struct PatternKey: Hashable, Codable, Sendable {
    public let toolName: String
    public let argShape: String     // args normalizados, sin valores volátiles
    public let errorClass: String   // taxonomía del ErrorClassifier + errores de tool
    public let targetResource: String?

    public init(toolName: String, argShape: String, errorClass: String, targetResource: String?) {
        self.toolName = toolName
        self.argShape = argShape
        self.errorClass = errorClass
        self.targetResource = targetResource
    }

    /// Clave estable: hash SHA256 de los cuatro componentes (prefijo 16 hex).
    public var key: String {
        Self.hashPrefix("\(toolName)|\(argShape)|\(errorClass)|\(targetResource ?? "-")")
    }

    static func hashPrefix(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: - Normalización de args

    /// Forma canónica de un input de tool sin valores volátiles.
    public static func argShape(from value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "<bool>"
        case .int, .double: return "<n>"
        case .string(let s): return normalize(string: s)
        case .array(let a): return "[" + a.map { argShape(from: $0) }.joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { "\($0):\(argShape(from: o[$0]!))" }.joined(separator: ",") + "}"
        }
    }

    static func normalize(string s: String) -> String {
        if isUUIDLike(s) { return "<id>" }
        if s.contains("/") {
            let dir = (s as NSString).deletingLastPathComponent
            return dir.isEmpty ? "<path>" : "<path:\(dir)>"
        }
        if isDateLike(s) { return "<date>" }
        return "<text>"
    }

    static func isUUIDLike(_ s: String) -> Bool {
        if UUID(uuidString: s) != nil { return true }
        // ids opacos: cadenas largas hex/alfanuméricas con separadores.
        let hexish = s.allSatisfy { $0.isHexDigit || $0 == "-" || $0 == "_" }
        return hexish && s.count >= 12 && s.contains(where: { $0.isNumber })
    }

    static func isDateLike(_ s: String) -> Bool {
        // YYYY-MM-DD, ISO 8601 o timestamps con "T".
        guard s.count >= 8 else { return false }
        let prefix = s.prefix(10)
        let parts = prefix.split(separator: "-")
        if parts.count == 3, parts[0].count == 4,
           parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return true }
        return false
    }

    // MARK: - Clase de error

    /// Taxonomía del §5.6 a partir del texto de un tool_result de error.
    public static func errorClass(fromToolResult content: String) -> String {
        let s = content.lowercased()
        if s.contains("no permitida") || s.contains("permission") || s.contains("cancelada")
            || s.contains("no confirmó") || s.contains("no la confirmó") || s.contains("denied") {
            return "permission_denied"
        }
        if s.contains("no encontrad") || s.contains("not found") || s.contains("desconocida")
            || s.contains("sin resultado") {
            return "not_found"
        }
        if s.contains("timeout") || s.contains("excedió") || s.contains("timed out") {
            return "timeout"
        }
        if s.contains("inválid") || s.contains("invalid") || s.contains("input") {
            return "invalid_input"
        }
        return "os_error"
    }

    /// Taxonomía del §5.6 a partir de un ClassifiedError del provider.
    public static func errorClass(from error: ClassifiedError) -> String {
        switch error {
        case .rateLimited: return "rate_limited"
        case .retryable: return "retryable"
        case .contextOverflow: return "context_overflow"
        case .fatal: return "fatal"
        }
    }
}

/// Un fallo observado, listo para `RealRegister.record`.
public struct Failure: Sendable, Equatable {
    public var pattern: PatternKey
    public var sessionId: SessionID?
    public var rawError: String
    public var timestamp: Date

    public init(pattern: PatternKey, sessionId: SessionID?, rawError: String, timestamp: Date) {
        self.pattern = pattern
        self.sessionId = sessionId
        self.rawError = rawError
        self.timestamp = timestamp
    }

    /// Fallo de una tool client-side (Sensorimotor.execute con isError).
    public static func tool(name: String, input: JSONValue, result: ToolResult,
                            sessionId: SessionID?, now: Date) -> Failure {
        let pattern = PatternKey(
            toolName: name,
            argShape: PatternKey.argShape(from: input),
            errorClass: PatternKey.errorClass(fromToolResult: result.content),
            targetResource: targetResource(from: input))
        return Failure(pattern: pattern, sessionId: sessionId, rawError: result.content, timestamp: now)
    }

    /// Fallo del LoopDetector (misma tool+input en bucle): la estrategia insiste.
    public static func loop(name: String, input: JSONValue, sessionId: SessionID?, now: Date) -> Failure {
        let pattern = PatternKey(
            toolName: name,
            argShape: PatternKey.argShape(from: input),
            errorClass: "loop_detected",
            targetResource: targetResource(from: input))
        return Failure(pattern: pattern, sessionId: sessionId, rawError: "loop detected", timestamp: now)
    }

    /// Fallo fatal del provider (ErrorClassifier), no reintentable.
    public static func classified(toolName: String, error: ClassifiedError,
                                  sessionId: SessionID?, now: Date) -> Failure {
        let pattern = PatternKey(toolName: toolName, argShape: "<call>",
                                 errorClass: PatternKey.errorClass(from: error), targetResource: nil)
        return Failure(pattern: pattern, sessionId: sessionId, rawError: "\(error)", timestamp: now)
    }

    static func targetResource(from input: JSONValue) -> String? {
        for key in ["calendar", "domain", "resource", "target", "type", "list"] {
            if let s = input[key]?.stringValue, !s.isEmpty { return s }
        }
        return nil
    }
}
