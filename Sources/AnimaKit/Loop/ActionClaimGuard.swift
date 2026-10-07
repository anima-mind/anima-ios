// ActionClaimGuard.swift — "nunca afirmar una escritura que no ocurrió"
// (campo batch 8 #6, todos los proveedores). Medido con Claude: aceptó la
// propuesta de check-in y respondió "Listo, te programo el check-in… Quedó
// agendado" SIN llamar ninguna tool. Si el texto final afirma una acción de
// escritura y en el turno no hubo una tool de escritura exitosa, el loop pide
// UNA vez ejecutarla; si aun así no la ejecuta, antepone la línea fija
// (mismo mecanismo que ToolFailureNotice).

import Foundation

public enum ActionClaimGuard {
    /// La línea que se antepone cuando el reintento tampoco ejecutó nada.
    public static let marker = "⚠️ Aún no lo dejé programado"
    public static let notice = marker + ": no se ejecutó ninguna acción. Pídemelo de nuevo y lo hago."

    /// Abre el turno sintético del reintento (no se persiste ni se pinta).
    public static let nudgeMarker = "[Verificación del harness]"
    public static let nudge = nudgeMarker + """
     Tu respuesta afirma que agendaste, programaste, registraste o creaste algo, pero en este turno \
    NO se ejecutó ninguna herramienta de escritura: nada quedó guardado. Si el dueño lo pidió o lo \
    aceptó, EJECUTA ahora la herramienta que corresponde (anima_reminders create con su goal_id, goals \
    set_checkin o declare, calendar create, notes…) y después confírmalo en una frase. Si no corresponde \
    hacer nada o ya existía de antes, dilo sin afirmar que lo hiciste ahora.
    """

    /// Tools que escriben en el mundo del dueño (las de lectura no cuentan).
    static let writeTools: Set<String> = ["anima_reminders", "goals", "calendar", "notes", "reminders"]
    static let readActions: Set<String> = ["list", "search", "read", "get"]

    /// ¿Esta llamada (real, ya traducida) es una escritura?
    public static func isWrite(tool: String, input: JSONValue) -> Bool {
        guard writeTools.contains(tool) else { return false }
        return !readActions.contains(input["action"]?.stringValue ?? "")
    }

    /// ¿Hay al menos una tool de escritura disponible en el turno?
    public static func canWrite(_ specs: [ToolSpec]) -> Bool {
        specs.contains { spec in
            writeTools.contains(LocalToolAdapter.tool(named: spec.name)?.realTool ?? spec.name)
        }
    }

    // Afirmaciones de escritura en primera persona, CON tildes: "programé"
    // (pretérito, afirma) ≠ "programe" (subjuntivo, "¿quieres que te lo
    // programe?"). Los participios sueltos ("está programado") describen, no
    // afirman: solo cuentan tras "quedó"/"dejé".
    private static let claimPatterns = [
        #"\b(agendé|programé|registré|creé|anoté|apunté|guardé|dejé|fijé)\b"#,
        #"\bte (lo |la )?programo\b"#,
        #"\b(ya )?quedó (agendad|programad|registrad|cread|guardad|anotad|fijad|apuntad)[a-z]*"#,
        #"\blisto,? (ya )?quedó\b"#,
        #"\bte (lo |la )?recuerdo\b(?! que)"#,
        #"\bte voy a recordar\b"#,
        #"\bte aviso (el|la|los|las|mañana|hoy|a las|en|cada|cuando)\b"#,
    ]
    private static let claimRegexes = claimPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
    private static let exemptions = ["ya existía", "ya existia", "ya estaba", "ya lo tenías", "ya la tenías", "ya tenías"]
    /// Ofertas y condicionales: proponen, no afirman.
    private static let offers = ["quieres que", "si quieres", "cuando quieras", "puedo ", "podría", "te parece",
                                 "te gustaría", "prefieres", "si me dices", "si me confirmas", "dime si"]
    /// Lo hecho en OTRO turno ("ya te lo programé ayer") no es de este.
    private static let earlier = ["ayer", "antes", "el otro día", "la semana pasada", "hace un rato", "anoche"]

    static func fold(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
    }

    /// Oraciones con su terminador ("?" marca pregunta aunque falte el "¿").
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?\n".contains(ch) {
                out.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(current) }
        return out
    }

    /// ¿El texto afirma haber hecho (o estar haciendo) una escritura en ESTE
    /// turno? No cuentan: preguntas y ofertas, negadas, lo que ya existía o se
    /// hizo antes, ni "te recuerdo que…" informativo.
    public static func claimsWrite(_ text: String) -> Bool {
        guard !ToolFailureNotice.admits(text) else { return false }
        for sentence in sentences(text) {
            let lower = sentence.lowercased()
            if lower.contains("?") || lower.contains("¿") { continue }
            if offers.contains(where: lower.contains) || exemptions.contains(where: lower.contains) { continue }
            if lower.contains("no puedo") || lower.contains("no lo puedo") { continue }
            if lower.contains("ya "), earlier.contains(where: lower.contains) { continue }
            let ns = lower as NSString
            for regex in claimRegexes {
                for match in regex.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
                    let start = max(0, match.range.location - 14)
                    let before = ns.substring(with: NSRange(location: start, length: match.range.location - start))
                    let negated = ["no ", "nunca ", "sin ", "aún no", "aun no", "todavía no", "todavia no"]
                        .contains { before.contains($0) }
                    if !negated { return true }
                }
            }
        }
        return false
    }
}

/// "Hagámoslo" en una propuesta del deseo (§5.8): el turno que viaja al loop
/// pide EJECUTARLA con la tool que corresponde — no solo contestar. En el chat
/// se ve como "Hagámoslo" (el texto largo es instrucción, no algo que el dueño escribió).
public enum IntentionAcceptance {
    public static let marker = "[Propuesta aceptada]"
    public static let shownText = "Hagámoslo"

    public static func prompt(proposal: String, goalId: String?) -> String {
        let goal = goalId.map { " con goal_id \($0)" } ?? ""
        return """
        \(marker) Acepto tu propuesta: «\(proposal)».
        EJECÚTALA YA con la herramienta que corresponde — no basta con responder:
        - check-in o seguimiento de la meta → `goals` set_checkin\(goal) (la cadencia y la hora que propusiste);
        - un aviso puntual → `anima_reminders` create\(goal), con fire_at y message;
        - un bloque en la agenda → `calendar` create.
        Después dime en una frase qué quedó programado y cuándo. Si no puedes hacerlo, dímelo claro.
        """
    }

    public static func isAcceptance(_ text: String) -> Bool { text.hasPrefix(marker) }
}

extension ActionClaimGuard {
    static func isNudge(_ text: String) -> Bool { text.hasPrefix(nudgeMarker) }
}
