// SkillStore.swift — lector del dir sandbox de skills (Documents/skills; doc 05
// §6.2: editar skills sin release). Hot-reload
// simple: cada lectura lista el dir y compara la firma (ruta + mtime + tamaño);
// solo re-parsea si cambió. Layouts aceptados: `skills/<x>.md` y
// `skills/<x>/SKILL.md` (doc 05). `skills/drafts/` no se carga (borradores).

import Foundation

public final class SkillStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var signature: [String] = []
    private var cache: [Skill] = []
    private var _reloads = 0

    public init(directory: URL) {
        self.directory = directory
    }

    /// Cuántas veces se re-parseó el dir (observabilidad del hot-reload).
    public var reloadCount: Int { lock.lock(); defer { lock.unlock() }; return _reloads }

    /// Los skills vigentes; re-parsea solo si la firma del dir cambió.
    public func skills() -> [Skill] {
        let files = Self.skillFiles(in: directory)
        let current = files.map(Self.fingerprint)
        lock.lock(); defer { lock.unlock() }
        if current != signature {
            signature = current
            cache = files.compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).flatMap(SkillEngine.parse)
            }
            _reloads += 1
        }
        return cache
    }

    /// Archivos de skill del dir, en orden estable por ruta relativa.
    static func skillFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var files: [URL] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                guard entry.lastPathComponent != "drafts" else { continue }
                let nested = entry.appendingPathComponent("SKILL.md")
                if fm.fileExists(atPath: nested.path) { files.append(nested) }
            } else if entry.pathExtension.lowercased() == "md" {
                files.append(entry)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func fingerprint(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        return "\(url.lastPathComponent)|\(url.deletingLastPathComponent().lastPathComponent)|\(mtime)|\(size)"
    }
}

/// Siembra de skills de ejemplo (los que el shell trae en su bundle) al primer
/// arranque: solo si el dir del dueño no tiene ningún skill. Idempotente.
public enum SkillSeeder {
    /// Copia los `*.md` de `source` a `destination` si este no tiene skills.
    /// Devuelve los nombres de archivo copiados (vacío ⇒ no hizo nada).
    @discardableResult
    public static func seedIfEmpty(from source: URL?, to destination: URL) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard SkillStore.skillFiles(in: destination).isEmpty, let source,
              let seeds = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        else { return [] }
        var copied: [String] = []
        for seed in seeds.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where seed.pathExtension.lowercased() == "md" {
            try fm.copyItem(at: seed, to: destination.appendingPathComponent(seed.lastPathComponent))
            copied.append(seed.lastPathComponent)
        }
        return copied
    }
}
