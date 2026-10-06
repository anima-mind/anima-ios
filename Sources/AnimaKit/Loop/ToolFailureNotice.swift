// ToolFailureNotice.swift — "nunca mentir tras un error" (determinista, todos
// los proveedores). Medido con el modelo de Apple: tras un error de tool
// respondía "He programado un recordatorio…". Si una tool falló en el turno y
// ninguna ejecución posterior de la MISMA intención la salvó, y el texto final
// no lo admite, el loop antepone una línea fija con el error legible (también
// si el dueño rechazó la confirmación: "no lo confirmaste").

import Foundation

public enum ToolFailureNotice {
    public static let marker = "⚠️ No pude"

    /// La intención de una llamada real, como verbo ("crear el recordatorio").
    public static func verb(tool: String, input: JSONValue) -> String {
        let action = input["action"]?.stringValue ?? ""
        switch (tool, action) {
        case ("anima_reminders", "list"): return "consultar tus recordatorios"
        case ("anima_reminders", "complete"): return "marcar el recordatorio como hecho"
        case ("anima_reminders", "cancel"): return "cancelar el recordatorio"
        case ("anima_reminders", "snooze"): return "posponer el recordatorio"
        case ("anima_reminders", _): return "crear el recordatorio"
        case ("goals", "list"): return "consultar tus metas"
        case ("goals", "record_checkin"): return "anotar el seguimiento"
        case ("goals", "mark_achieved"): return "marcar la meta como lograda"
        case ("goals", _): return "registrar la meta"
        case ("calendar", "list"), ("calendar", "search"): return "consultar tu agenda"
        case ("calendar", "delete"): return "borrar el evento"
        case ("calendar", _): return "crear el evento"
        case ("notes", "read"): return "leer la nota"
        case ("notes", "list"): return "consultar tus notas"
        case ("notes", _): return "guardar la nota"
        case ("reminders", "list"): return "consultar la app Recordatorios"
        case ("reminders", "complete"): return "completar el recordatorio del iPhone"
        case ("reminders", _): return "crear el recordatorio en la app Recordatorios"
        default: return "completar la acción (\(ToolNames.friendly(tool)))"
        }
    }

    /// ¿El texto ya admite el fallo? (no se duplica la línea).
    /// Solo admisiones en negativo: "sin errores" o "a prueba de fallos" no admiten nada.
    public static func admits(_ text: String) -> Bool {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
        return admissions.contains { folded.contains($0) }
    }

    static let admissions = ["no pude", "no logre", "no se pudo", "no fue posible", "no he podido", "no consegui",
                             "hubo un error", "hubo error", "ocurrio un error", "dio error", "dio un error",
                             "fallo al", "fallo el", "fallo la", "fallo porque", "fallo.", "fallo,",
                             "no se creo", "no se guardo", "no se agendo", "no se registro"]

    /// El error de la tool, legible y corto ("la fecha ya pasó").
    public static func legible(_ error: String) -> String {
        var text = error
        if let hint = text.range(of: " Corrige y llama") { text = String(text[..<hint.lowerBound]) }
        for prefix in ["Error: ", "Error:"] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        // Detalle técnico fuera (SQL, rutas): la primera línea, sin el "while executing".
        if result(isRejection: text) { return "no lo confirmaste" }
        // Errores de permiso de las tools, en 2.ª persona.
        text = text.replacingOccurrences(of: "El dueño no ha concedido acceso", with: "no me has dado acceso")
            .replacingOccurrences(of: "el dueño no ha concedido acceso", with: "no me has dado acceso")
            .replacingOccurrences(of: "El dueño", with: "Tú")
        for cut in ["\n", " - while executing"] {
            if let range = text.range(of: cut) { text = String(text[..<range.lowerBound]) }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        if text.count > 120 { text = String(text.prefix(117)) + "…" }
        return text.isEmpty ? "la herramienta falló" : text
    }

    static func result(isRejection text: String) -> Bool {
        text.hasPrefix("Acción cancelada: el dueño no la confirmó")
    }

    public static func line(verb: String, error: String) -> String {
        "\(marker) \(verb): \(legible(error))."
    }

    /// La(s) línea(s) a anteponer, o nil si no hace falta.
    public static func notice(failures: [(verb: String, error: String)], finalText: String) -> String? {
        guard !failures.isEmpty, !admits(finalText) else { return nil }
        return failures.map { line(verb: $0.verb, error: $0.error) }.joined(separator: "\n")
    }

    /// El contenido con la línea al frente del primer bloque de texto.
    public static func prepend(_ notice: String, to content: [ContentBlock]) -> [ContentBlock] {
        guard let index = content.firstIndex(where: { if case .text = $0 { return true } else { return false } }),
              case .text(let text) = content[index] else {
            return [.text(notice)] + content
        }
        var out = content
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        out[index] = .text(trimmed.isEmpty ? notice : notice + "\n\n" + trimmed)
        return out
    }
}

/// Fallos vivos del turno por intención (verbo): una ejecución exitosa
/// posterior de la misma intención los borra. Un rechazo del dueño también
/// cuenta: tras él, "Listo" sería mentira ("No pude…: no lo confirmaste").
struct TurnFailures {
    private(set) var entries: [(verb: String, error: String)] = []

    mutating func record(verb: String, result: ToolResult) {
        entries.removeAll { $0.verb == verb }
        if result.isError { entries.append((verb, result.content)) }
    }
}
