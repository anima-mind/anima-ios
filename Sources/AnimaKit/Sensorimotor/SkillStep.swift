// SkillStep.swift — un paso del front-matter `steps:` de un skill, leído como
// llamada de tool: `tool.operación(arg=valor, …)`. La clasificación
// aferente/eferente del SkillEngine y el SkillRunner parten de aquí.
//
// Gramática mínima (a propósito: lo que no es determinístico lo decide el LLM):
//   paso        := tool "." operación [ "(" args ")" ] [ "?" ]
//   args        := arg { "," arg }          — sin comas dentro de los valores
//   arg         := clave "=" valor
//   valor       := literal | literal con placeholders | "…" | '…'
//   placeholder := {hoy}   → fecha local ISO AAAA-MM-DD
//                | {turno} → el texto del turno del dueño
//   "?" final   := paso opcional: si falla, el runner anota "sin resultado" y
//                  sigue (p.ej. leer la nota de hoy que aún no existe).
// Enteros y true/false literales viajan tipados; lo demás, como string. Un arg
// sin valor (`content`), un `<descripción>` o un placeholder desconocido NO se
// resuelven ⇒ el runner aborta la automatización (cae a inyección normal).

import Foundation

/// Contexto determinístico para resolver placeholders.
public struct SkillRunContext: Sendable, Equatable {
    public var turnText: String
    public var now: Date
    public var timeZone: TimeZone

    public init(turnText: String, now: Date, timeZone: TimeZone = .current) {
        self.turnText = turnText
        self.now = now
        self.timeZone = timeZone
    }

    /// `{hoy}`: fecha local del dueño en ISO (AAAA-MM-DD).
    public var today: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func value(of placeholder: String) -> String? {
        switch placeholder {
        case "hoy": return today
        case "turno":
            let text = turnText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        default: return nil
        }
    }
}

/// Un paso resuelto a llamada concreta de tool, listo para el Sensorimotor.
public struct SkillStepCall: Sendable, Equatable {
    public var step: String         // el paso tal cual en el markdown
    public var display: String      // el paso con placeholders resueltos (para el bloque/UI)
    public var tool: String
    public var operation: String
    public var input: JSONValue     // {"action": operación, args…}
    public var optional: Bool
}

/// Por qué un paso no se pudo resolver determinísticamente.
public enum SkillStepResolutionError: Error, Sendable, Equatable {
    case notACall(step: String)
    case unresolvedArgument(step: String, argument: String)
}

public enum SkillStep {
    /// "calendar.list(days_ahead=7)" → "calendar.list"; nil si no tiene la forma
    /// `tool.operación` (un paso en prosa no es ejecutable ⇒ eferente, fail-closed).
    static func operationKey(_ step: String) -> String? {
        var trimmed = step.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("?") { trimmed.removeLast() }
        let head = trimmed.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
        let parts = head.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } })
        else { return nil }
        return head
    }

    /// Resuelve un paso a llamada de tool con la gramática mínima de arriba.
    public static func resolve(_ step: String, context: SkillRunContext) -> Result<SkillStepCall, SkillStepResolutionError> {
        var text = step.trimmingCharacters(in: .whitespaces)
        let optional = text.hasSuffix("?")
        if optional { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard let key = operationKey(text) else { return .failure(.notACall(step: step)) }
        let parts = key.split(separator: ".").map(String.init)

        var argsText = ""
        if let open = text.firstIndex(of: "(") {
            guard text.hasSuffix(")") else { return .failure(.notACall(step: step)) }
            argsText = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        }
        var input: [String: JSONValue] = ["action": .string(parts[1])]
        var shown: [String] = []
        for raw in argsText.split(separator: ",", omittingEmptySubsequences: true) {
            let arg = raw.trimmingCharacters(in: .whitespaces)
            if arg.isEmpty { continue }
            guard let eq = arg.firstIndex(of: "=") else {
                return .failure(.unresolvedArgument(step: step, argument: arg))
            }
            let name = arg[..<eq].trimmingCharacters(in: .whitespaces)
            let rawValue = unquote(arg[arg.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            guard !name.isEmpty, name != "action", !rawValue.contains("<"),
                  let value = interpolate(rawValue, context: context, strict: true), !value.isEmpty
            else { return .failure(.unresolvedArgument(step: step, argument: arg)) }
            input[name] = typed(value, literal: !rawValue.contains("{"))
            shown.append("\(name)=\(value)")
        }
        let display = "\(key)(\(shown.joined(separator: ", ")))" + (optional ? "?" : "")
        return .success(SkillStepCall(step: step, display: display, tool: parts[0], operation: parts[1],
                                      input: .object(input), optional: optional))
    }

    /// Sustituye `{hoy}`/`{turno}`. `strict`: un placeholder desconocido o vacío
    /// ⇒ nil. No estricto (para mostrar pasos pendientes): deja lo desconocido.
    public static func interpolate(_ text: String, context: SkillRunContext, strict: Bool = false) -> String? {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                if strict { return nil }
                out += rest[open...]
                return out
            }
            let name = String(rest[rest.index(after: open)..<close])
            if let value = context.value(of: name) {
                out += value
            } else if strict {
                return nil
            } else {
                out += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    private static func unquote(_ s: String) -> String {
        for q in ["\"", "'"] where s.count >= 2 && s.hasPrefix(q) && s.hasSuffix(q) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func typed(_ value: String, literal: Bool) -> JSONValue {
        guard literal else { return .string(value) }
        if let n = Int(value) { return .int(n) }
        if value == "true" { return .bool(true) }
        if value == "false" { return .bool(false) }
        return .string(value)
    }
}
