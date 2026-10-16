// ReengagementDraft.swift — la etapa barata del sueño que deja listas las
// preguntas de los avisos por inactividad: UNA llamada al córtex del ciclo con
// lo que Anima sabe (memorias recientes, metas y su avance, lo que el dueño
// contó), 3–5 preguntas cortas en su voz y en el idioma del dueño. El parseo es
// tolerante y el filtro determinista: sin cifras, citas, salud ni dinero.

import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public enum ReengagementDraft {
    public static let maxQuestions = 5
    static let maxMemories = 10
    static let maxMessages = 8
    static let maxMessageLength = 160
    static let memoryWindow: TimeInterval = 14 * 24 * 3600

    /// Lo que entra al prompt.
    public struct Material: Sendable, Equatable {
        public var selfName: String
        public var style: String
        public var language: String
        public var memories: [String]
        public var goals: [String]
        public var messages: [String]
        /// Metas que el dueño dejó o cambió: no se pregunta por ellas.
        public var leftGoals: [String]

        public init(selfName: String, style: String, language: String, memories: [String], goals: [String],
                    messages: [String], leftGoals: [String] = []) {
            self.selfName = selfName
            self.style = style
            self.language = language
            self.memories = memories
            self.goals = goals
            self.messages = messages
            self.leftGoals = leftGoals
        }

        /// Sin nada que anclar, la etapa no gasta la llamada (quedan las de respaldo).
        public var isEmpty: Bool { memories.isEmpty && goals.isEmpty && messages.isEmpty }
    }

    public static func system(_ material: Material) -> String {
        """
        Eres \(material.selfName), la mente personal que vive en el teléfono de tu dueño. \
        \(material.style.isEmpty ? "" : "Tu estilo: \(material.style) ")\
        Escribe las preguntas que le harás por notificación si pasa unos días sin hablarte, \
        para que tenga ganas de contarte cómo va.

        Reglas:
        - Entre 3 y 5 preguntas. Cada una es UNA frase corta (máximo 80 caracteres), en segunda persona, cálida y abierta.
        - Ánclalas en lo que sabes de él: algo que te contó, una meta y su avance, cómo ha estado de ánimo.
        - Nada de presión ni culpa ("¿por qué no me escribes?"), nada de vender ni de hablar de ti.
        - Van en una notificación que otros pueden ver: NADA de salud, diagnósticos, medicamentos, dinero, montos, deudas, asuntos legales, adicciones, pareja, cifras ni citas textuales. Si el tema es delicado, pregunta en general ("¿Cómo has estado estos días?").
        - No preguntes por la salud, el dinero ni la vida privada de otras personas.
        - Sin números, sin comillas, sin emojis.
        - Escribe en \(material.language).

        Devuelve SOLO un arreglo JSON de strings: ["¿…?", "¿…?"]
        """
    }

    public static func user(_ material: Material) -> String {
        func block(_ title: String, _ items: [String]) -> String {
            items.isEmpty ? "" : "\(title):\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        return block("Lo que sabes del dueño (memorias recientes)", material.memories)
            + block("Sus metas y cómo van", material.goals)
            + block("Lo último que te contó", material.messages)
            + block("Metas que el dueño DEJÓ o cambió (NO preguntes por ellas)", material.leftGoals)
            + "Devuelve SOLO el arreglo JSON."
    }

    /// Fuera las preguntas sobre una meta que el dueño dejó ("¿Cómo vas con el
    /// ahorro?" tras "ya no quiero ahorrar"), salvo que hablen más de una vigente.
    public static func withoutLeftGoals(_ questions: [String], left: [String], active: [String]) -> [String] {
        guard !left.isEmpty else { return questions }
        func overlap(_ a: String, _ b: String) -> Int { stems(a).intersection(stems(b)).count }
        return questions.filter { question in
            let leftOverlap = left.map { overlap(question, $0) }.max() ?? 0
            let activeOverlap = active.map { overlap(question, $0) }.max() ?? 0
            return leftOverlap == 0 || activeOverlap > leftOverlap
        }
    }

    /// Raíces simples ("ahorrando", "ahorro", "Ahorrar" ⇒ "ahorr"): las palabras
    /// de contenido cortadas a 5 letras.
    static func stems(_ text: String) -> Set<String> {
        Set(GoalDedupe.contentTerms(text).map { $0.count > 5 ? String($0.prefix(5)) : $0 })
    }

    // MARK: - Parseo tolerante

    private struct Wrapped: Decodable { let questions: [String] }
    private struct Item: Decodable {
        let text: String?
        let question: String?
        var value: String? { text ?? question }
    }

    /// Arreglo de strings, de objetos {text|question}, {"questions":[…]} o, si
    /// nada de eso, las líneas con "?". Filtradas, sin repetir y a lo sumo 5.
    public static func parse(_ text: String) -> [String] {
        let raw: [String]
        if let list = Consolidator.decode([String].self, from: text) {
            raw = list
        } else if let wrapped = Consolidator.decode(Wrapped.self, from: text) {
            raw = wrapped.questions
        } else if let items = Consolidator.decode([Item].self, from: text) {
            raw = items.compactMap(\.value)
        } else {
            raw = text.components(separatedBy: .newlines).filter { $0.contains("?") }
        }
        var seen = Set<String>()
        var out: [String] = []
        for candidate in raw.map(clean) where ReengagementTextGuard.isAllowed(candidate) {
            guard seen.insert(ReengagementTextGuard.key(candidate)).inserted else { continue }
            out.append(candidate)
            if out.count == maxQuestions { break }
        }
        return out
    }

    static let bullet = ICURegex(#"^(\d+[\.\)]|[-*•])\s*"#)

    /// Quita viñetas, numeración, comillas envolventes y espacios de más.
    static func clean(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = bullet.firstMatch(in: s) { s.removeSubrange(match.range) }
        let wrappers: Set<Character> = ["\"", "'", "“", "”", "«", "»", "`"]
        while let first = s.first, wrappers.contains(first) { s.removeFirst() }
        while let last = s.last, wrappers.contains(last) || last == "," { s.removeLast() }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Idioma del dueño

    /// El idioma en que escribe el dueño (sus mensajes), si se reconoce con
    /// confianza; si no, el idioma por defecto del self ("español (es-CO)").
    public static func language(of messages: [String], fallback: String) -> String {
        #if canImport(NaturalLanguage)
        let joined = messages.joined(separator: " ")
        guard joined.count >= 20 else { return fallback }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(joined)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.6 else { return fallback }
        let names: [NLLanguage: String] = [.spanish: "español", .english: "inglés (English)",
                                          .portuguese: "portugués", .french: "francés", .italian: "italiano",
                                          .german: "alemán"]
        if language == .spanish, fallback.lowercased().contains("español") { return fallback }
        return names[language] ?? fallback
        #else
        return fallback
        #endif
    }

    /// "Idioma por defecto: español (es-CO)." dentro del estilo del self.
    static func defaultLanguage(fromStyle style: String) -> String {
        guard let range = style.range(of: "Idioma por defecto:") else { return "español" }
        let rest = style[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let value = rest.prefix { $0 != "." && $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "español" : value
    }

    static func shorten(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count <= maxMessageLength ? flat : String(flat.prefix(maxMessageLength)) + "…"
    }
}
