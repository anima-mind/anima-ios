// NotesTool.swift — tool client-side (§5.7): notas en un sandbox de archivos.
// Ejercita el camino client-side del tool loop (crear/leer/listar/append).
// Guardrails determinísticos ACI: valida input antes de tocar el FS, output
// vacío se reemplaza por texto explícito.

import Foundation

public struct NotesTool: HarnessTool {
    private let root: URL

    /// `root`: directorio sandbox. Default = Documents/notes; inyectable para tests.
    public init(root: URL) {
        self.root = root
    }

    public init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(root: base.appendingPathComponent("notes", isDirectory: true))
    }

    public var spec: ToolSpec {
        .client(
            name: "notes",
            description: """
                Notas persistentes del asistente en su sandbox. Úsala para crear, leer, \
                listar o anexar notas de texto. Acciones: create (crea/reemplaza), \
                read (lee una nota), list (lista nombres), append (anexa al final).
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "enum": .array([.string("create"), .string("read"), .string("list"), .string("append")]),
                        "description": .string("Operación a realizar."),
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Nombre de la nota (sin ruta). Requerido salvo en list."),
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("Texto para create/append."),
                    ]),
                ]),
                "required": .array([.string("action")]),
                "additionalProperties": .bool(false),
            ]))
    }

    public func execute(_ input: JSONValue) async -> ToolResult {
        guard let action = input["action"]?.stringValue else {
            return ToolResult(content: "Error: falta 'action'.", isError: true)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            switch action {
            case "list":
                return listNotes()
            case "read":
                guard let name = sanitizedName(input) else {
                    return ToolResult(content: "Error: 'name' inválido o ausente.", isError: true)
                }
                return readNote(name)
            case "create":
                guard let name = sanitizedName(input) else {
                    return ToolResult(content: "Error: 'name' inválido o ausente.", isError: true)
                }
                let content = input["content"]?.stringValue ?? ""
                try content.write(to: fileURL(name), atomically: true, encoding: .utf8)
                return ToolResult(content: "Nota '\(name)' guardada (\(content.count) caracteres).")
            case "append":
                guard let name = sanitizedName(input) else {
                    return ToolResult(content: "Error: 'name' inválido o ausente.", isError: true)
                }
                let addition = input["content"]?.stringValue ?? ""
                return appendNote(name, addition: addition)
            default:
                return ToolResult(content: "Error: acción desconocida '\(action)'.", isError: true)
            }
        } catch {
            return ToolResult(content: "Error de sistema de archivos: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Operaciones

    private func listNotes() -> ToolResult {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        if names.isEmpty { return ToolResult(content: "No hay notas todavía.") }
        return ToolResult(content: names.sorted().joined(separator: "\n"))
    }

    private func readNote(_ name: String) -> ToolResult {
        guard let text = try? String(contentsOf: fileURL(name), encoding: .utf8) else {
            return ToolResult(content: "La nota '\(name)' no existe.", isError: true)
        }
        return ToolResult(content: text.isEmpty ? "(nota vacía)" : text)
    }

    private func appendNote(_ name: String, addition: String) -> ToolResult {
        let existing = (try? String(contentsOf: fileURL(name), encoding: .utf8)) ?? ""
        let updated = existing.isEmpty ? addition : existing + "\n" + addition
        do {
            try updated.write(to: fileURL(name), atomically: true, encoding: .utf8)
            return ToolResult(content: "Anexado a '\(name)'.")
        } catch {
            return ToolResult(content: "Error al anexar: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Guardrails

    /// Normaliza el nombre a un componente simple dentro del sandbox (sin traversal).
    private func sanitizedName(_ input: JSONValue) -> String? {
        guard let raw = input["name"]?.stringValue else { return nil }
        let base = (raw as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "/", with: "")
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
        return cleaned
    }

    private func fileURL(_ name: String) -> URL {
        let withExt = name.hasSuffix(".txt") || name.hasSuffix(".md") ? name : name + ".txt"
        return root.appendingPathComponent(withExt)
    }
}

/// Spec de la tool server-side web_search (§5.7). Variante Opus 4.8 con dynamic
/// filtering: cero código cliente, el loop maneja pause_turn.
public enum WebSearchTool {
    public static let spec: ToolSpec = .server(type: "web_search_20260209", name: "web_search")
}
