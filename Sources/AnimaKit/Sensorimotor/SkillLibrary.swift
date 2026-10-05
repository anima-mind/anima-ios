// SkillLibrary.swift — escritura de skills del dueño en Documents/skills (campo
// batch 3, FIX A): crear (taller conversacional), importar desde Archivos,
// editar y eliminar. Las SEEDS son del dueño: también se editan/borran. El
// SkillStore hace el hot-reload por mtime, así que escribir el archivo basta
// para que la skill aparezca en la lista y en el match.
//
// La práctica (skill_practice) vive en la DB POR NOMBRE: renombrar una skill
// la vuelve una skill nueva (su racha empieza de cero). La UI lo avisa.

import Foundation

/// Markdown portable de una skill: front-matter + cuerpo (doc 05 §6.2, §5.7).
public enum SkillMarkdown {

    /// Último bloque `<skill>…</skill>` del texto del córtex (el borrador vigente).
    public static func extractBlock(from text: String) -> String? {
        guard let open = text.range(of: "<skill>", options: [.caseInsensitive, .backwards]) else { return nil }
        let after = text[open.upperBound...]
        guard let close = after.range(of: "</skill>", options: .caseInsensitive) else {
            // Bloque aún abierto (streaming): lo que va hasta ahora.
            let partial = String(after).trimmingCharacters(in: .whitespacesAndNewlines)
            return partial.isEmpty ? nil : partial
        }
        let block = String(after[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return block.isEmpty ? nil : stripFence(block)
    }

    /// El texto visible del mensaje: sin los bloques <skill> (van a la card).
    public static func strippingBlocks(_ text: String) -> String {
        var out = text
        while let open = out.range(of: "<skill>", options: .caseInsensitive) {
            if let close = out.range(of: "</skill>", options: .caseInsensitive, range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                out.removeSubrange(open.lowerBound..<out.endIndex)
            }
        }
        return out.replacingOccurrences(of: "\n\n\n", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Markdown canónico desde sus partes (lo que escribe el formulario/importador).
    public static func compose(name: String, when: String, description: String = "",
                               steps: [String] = [], requiresTools: [String] = [], body: String) -> String {
        var lines = ["---", "name: \(oneLine(name))"]
        if !description.isEmpty { lines.append("description: \(oneLine(description))") }
        lines.append("when: \(oneLine(when))")
        if !requiresTools.isEmpty { lines.append("requires_tools: [\(requiresTools.joined(separator: ", "))]") }
        if !steps.isEmpty {
            lines.append("steps:")
            lines += steps.map { "  - \(oneLine($0))" }
        }
        lines.append("---")
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return lines.joined(separator: "\n") + "\n" + (trimmedBody.isEmpty ? "" : trimmedBody + "\n")
    }

    /// Asegura un front-matter válido (con `name`). Si el texto ya parsea como
    /// skill, se respeta tal cual; si no, se envuelve: nombre = `fallbackName`,
    /// el texto entero pasa a ser el cuerpo (los pasos) y `when` = el nombre.
    public static func normalized(_ text: String, fallbackName: String) -> String {
        let clean = stripFence(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if SkillEngine.parse(clean) != nil { return clean.hasSuffix("\n") ? clean : clean + "\n" }
        let name = slug(fallbackName).isEmpty ? "skill" : slug(fallbackName)
        let when = fallbackName.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return compose(name: name, when: when, body: clean)
    }

    /// `"Regar las plantas!"` → `regar-las-plantas` (nombre de archivo y de skill).
    public static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .lowercased()
        var out = ""
        var lastDash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(60))
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Los modelos a veces envuelven el markdown en ```…```.
    static func stripFence(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeFirst() }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Operaciones de archivo sobre el dir de skills del dueño.
public struct SkillLibrary: Sendable {
    public enum LibraryError: Error, Equatable, LocalizedError {
        case invalid
        case unreadable
        public var errorDescription: String? {
            switch self {
            case .invalid: return "La skill no tiene un nombre válido."
            case .unreadable: return "No se pudo leer el archivo."
            }
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Archivo actual de la skill con ese nombre (front-matter `name`).
    public func file(named name: String) -> URL? {
        SkillStore.skillFiles(in: directory).first { url in
            (try? String(contentsOf: url, encoding: .utf8)).flatMap(SkillEngine.parse)?.name == name
        }
    }

    /// Markdown crudo de la skill (para el modo editar y "Ver ejemplo").
    public func markdown(named name: String) -> String? {
        file(named: name).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// Guarda una skill. `replacing`: el nombre original al editar — si el
    /// nombre no cambió se sobrescribe su archivo; si cambió, se escribe uno
    /// nuevo y se borra el viejo (la práctica NO migra: es otra skill).
    @discardableResult
    public func save(_ markdown: String, replacing original: String? = nil) throws -> Skill {
        guard let skill = SkillEngine.parse(markdown), !skill.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LibraryError.invalid
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = original.flatMap { file(named: $0) }
        let target: URL
        if let existing, original == skill.name {
            target = existing
        } else {
            target = uniqueURL(for: skill.name, excluding: existing)
        }
        let text = markdown.hasSuffix("\n") ? markdown : markdown + "\n"
        try text.write(to: target, atomically: true, encoding: .utf8)
        if let existing, existing != target {
            try? FileManager.default.removeItem(at: existing)
        }
        return skill
    }

    /// Importa un .md/.txt desde Archivos: valida el front-matter; si no lo
    /// tiene, lo envuelve con nombre = nombre del archivo y el texto como pasos.
    @discardableResult
    public func importFile(_ url: URL) throws -> Skill {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { throw LibraryError.unreadable }
        let name = url.deletingPathExtension().lastPathComponent
        return try save(SkillMarkdown.normalized(raw, fallbackName: name))
    }

    /// Elimina la skill (su archivo; si vive en `<x>/SKILL.md`, la carpeta).
    public func delete(named name: String) throws {
        guard let url = file(named: name) else { return }
        if url.lastPathComponent == "SKILL.md" {
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func uniqueURL(for name: String, excluding: URL?) -> URL {
        let base = SkillMarkdown.slug(name).isEmpty ? "skill" : SkillMarkdown.slug(name)
        var candidate = directory.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path), candidate != excluding {
            candidate = directory.appendingPathComponent("\(base)-\(n).md")
            n += 1
        }
        return candidate
    }
}
