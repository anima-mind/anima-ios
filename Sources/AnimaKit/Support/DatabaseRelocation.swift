// DatabaseRelocation.swift — mudanza ÚNICA y segura de `anima.sqlite` desde
// Documents al contenedor del App Group (los widgets leen lo que la app publica
// ahí). Regla: jamás perder un turno del dueño.
//
//   1. Si el grupo ya tiene la base → se usa (y se termina de retirar la vieja).
//   2. Si no hay base vieja → instalación nueva directo en el grupo.
//   3. Si hay vieja y no hay nueva → checkpoint del WAL, copia con la API de
//      backup de SQLite a un temporal, `PRAGMA integrity_check` + conteo de filas
//      de TODAS las tablas igual al origen (turnos, memorias, metas, …) + mismo
//      esquema; recién entonces rename atómico al nombre final y la vieja (y sus
//      sidecars) se renombran a `.migrated` — NUNCA se borran.
//   Cualquier fallo antes de instalar ⇒ se borra el temporal, se loguea y se
//   sigue con la base vieja intacta (se reintenta en el próximo arranque).

import Foundation
import GRDB
#if canImport(os)
import os
#endif

public struct DatabaseRelocation: Sendable {
    /// Pasos observables (tests de fallo a mitad inyectan un error en cualquiera).
    public enum Step: String, Sendable, CaseIterable {
        case prepare, checkpoint, copy, verify, protect, install, retireLegacy
    }

    public enum Outcome: Sendable, Equatable {
        /// Sin base previa: se crea en el grupo.
        case fresh
        /// Mudada en este arranque; `rows` = filas verificadas por tabla.
        case migrated(rows: [String: Int])
        /// Ya vivía en el grupo (arranques siguientes).
        case alreadyMigrated
        /// Falló algo: se sigue con la base vieja, intacta.
        case keptLegacy(reason: String)
        /// El binario no tiene contenedor del grupo (build sin firma): sandbox.
        case noGroupContainer
    }

    public struct Resolution: Sendable, Equatable {
        public var path: String
        public var outcome: Outcome
    }

    public enum RelocationError: Error, Equatable, LocalizedError {
        case integrity(String)
        case rowCountMismatch(table: String, source: Int, copy: Int)
        case schemaMismatch

        public var errorDescription: String? {
            switch self {
            case .integrity(let detail): return "integrity_check de la copia: \(detail)"
            case .rowCountMismatch(let table, let source, let copy):
                return "conteo distinto en \(table): origen \(source), copia \(copy)"
            case .schemaMismatch: return "el esquema de la copia no coincide con el origen"
            }
        }
    }

    public static let fileName = "anima.sqlite"
    public static let migratingSuffix = ".migrating"
    public static let retiredSuffix = ".migrated"
    /// Sidecars de SQLite que viajan con la base (WAL o rollback journal).
    public static let sidecars = ["-wal", "-shm", "-journal"]

    let legacyURL: URL
    let groupDirectory: URL?
    let protect: @Sendable (URL) -> Void
    let log: @Sendable (String) -> Void
    let fault: (@Sendable (Step, URL) throws -> Void)?

    /// - legacyURL: `Documents/anima.sqlite`.
    /// - groupDirectory: `<grupo>/Database` (nil sin entitlement).
    /// - protect: protección de archivo (AfterFirstUnlock en iOS).
    /// - fault: SOLO tests — se llama al entrar a cada paso con el temporal.
    public init(legacyURL: URL, groupDirectory: URL?,
                protect: @escaping @Sendable (URL) -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void = DatabaseRelocation.systemLog,
                fault: (@Sendable (Step, URL) throws -> Void)? = nil) {
        self.legacyURL = legacyURL
        self.groupDirectory = groupDirectory
        self.protect = protect
        self.log = log
        self.fault = fault
    }

    public var targetURL: URL? { groupDirectory?.appendingPathComponent(Self.fileName) }

    private var fileManager: FileManager { .default }

    // MARK: - Resolución

    /// Ruta que debe abrir la app en este arranque (corre UNA vez, antes de
    /// abrir cualquier conexión).
    public func resolve() -> Resolution {
        guard let groupDirectory, let target = targetURL else {
            return Resolution(path: legacyURL.path, outcome: .noGroupContainer)
        }
        if fileManager.fileExists(atPath: target.path) {
            if exists(legacyURL) {
                // Arranque previo interrumpido entre instalar y retirar.
                do { try retireLegacy() } catch { log("db-relocation: retiro pendiente falló: \(error)") }
            }
            return Resolution(path: target.path, outcome: .alreadyMigrated)
        }
        guard exists(legacyURL) else {
            do {
                try fileManager.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
                protect(groupDirectory)
                return Resolution(path: target.path, outcome: .fresh)
            } catch {
                log("db-relocation: no se pudo crear el directorio del grupo: \(error)")
                return Resolution(path: legacyURL.path, outcome: .keptLegacy(reason: "\(error)"))
            }
        }
        do {
            let rows = try migrate(to: target, in: groupDirectory)
            log("db-relocation: base mudada al App Group (\(rows.values.reduce(0, +)) filas verificadas)")
            do {
                try step(.retireLegacy, target)
                try retireLegacy()
            } catch {
                // La copia ya está instalada y verificada: se usa; el retiro se reintenta.
                log("db-relocation: base nueva en uso; retiro de la vieja pendiente: \(error)")
            }
            return Resolution(path: target.path, outcome: .migrated(rows: rows))
        } catch {
            cleanTemporary(in: groupDirectory)
            log("db-relocation: se sigue con la base de Documents (intacta): \(error)")
            return Resolution(path: legacyURL.path, outcome: .keptLegacy(reason: "\(error)"))
        }
    }

    // MARK: - Mudanza

    private func migrate(to target: URL, in directory: URL) throws -> [String: Int] {
        let temporary = directory.appendingPathComponent(Self.fileName + Self.migratingSuffix)
        try step(.prepare, temporary)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanTemporary(in: directory)

        let source = try DatabaseQueue(path: legacyURL.path)
        defer { try? source.close() }
        try step(.checkpoint, temporary)
        try source.writeWithoutTransaction { db in
            if try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal" {
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
        }
        let sourceRows = try source.read(Self.rowCounts)
        let sourceSchema = try source.read(Self.schema)

        try step(.copy, temporary)
        do {
            let copy = try DatabaseQueue(path: temporary.path)
            try source.backup(to: copy)
            // El backup hereda el modo WAL del origen; en el contenedor compartido
            // va en rollback journal (sin -shm con lock vivo al suspender: 0xdead10cc).
            try copy.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode=DELETE") }
            try copy.close()
        }

        try step(.verify, temporary)
        try Self.verify(copyAt: temporary, rows: sourceRows, schema: sourceSchema)

        try step(.protect, temporary)
        protect(directory)
        protect(temporary)

        try step(.install, temporary)
        try fileManager.moveItem(at: temporary, to: target)
        protect(target)
        return sourceRows
    }

    /// integrity_check = "ok", mismo esquema y mismo número de filas por tabla.
    static func verify(copyAt url: URL, rows expected: [String: Int], schema expectedSchema: [String]) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let copy = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? copy.close() }
        try copy.read { db in
            let report = try String.fetchAll(db, sql: "PRAGMA integrity_check")
            guard report == ["ok"] else { throw RelocationError.integrity(report.prefix(3).joined(separator: "; ")) }
            guard try schema(db) == expectedSchema else { throw RelocationError.schemaMismatch }
            let rows = try rowCounts(db)
            for (table, count) in expected.sorted(by: { $0.key < $1.key }) where rows[table] != count {
                throw RelocationError.rowCountMismatch(table: table, source: count, copy: rows[table] ?? -1)
            }
            if let extra = rows.keys.first(where: { expected[$0] == nil }) {
                throw RelocationError.rowCountMismatch(table: extra, source: -1, copy: rows[extra] ?? 0)
            }
        }
    }

    /// Filas por tabla (incluye las sombra del FTS: si una no cuadra, no cuadra).
    static func rowCounts(_ db: Database) throws -> [String: Int] {
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name
            """)
        var out: [String: Int] = [:]
        for table in tables {
            out[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)") ?? 0
        }
        return out
    }

    static func schema(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT type || ':' || name || ':' || IFNULL(sql, '') FROM sqlite_master
            WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name
            """)
    }

    // MARK: - Retiro (renombrar, nunca borrar)

    /// `anima.sqlite` → `anima.sqlite.migrated` (+ sidecars). Si ya hay un
    /// `.migrated` (no debería), se usa `.migrated.2`, `.3`… — nada se pisa.
    func retireLegacy() throws {
        let suffix = retiredSuffixAvailable()
        for sidecar in [""] + Self.sidecars {
            let url = URL(fileURLWithPath: legacyURL.path + sidecar)
            guard exists(url) else { continue }
            try fileManager.moveItem(at: url, to: URL(fileURLWithPath: legacyURL.path + suffix + sidecar))
        }
    }

    private func retiredSuffixAvailable() -> String {
        var suffix = Self.retiredSuffix
        var n = 2
        while exists(URL(fileURLWithPath: legacyURL.path + suffix)) {
            suffix = "\(Self.retiredSuffix).\(n)"
            n += 1
        }
        return suffix
    }

    private func cleanTemporary(in directory: URL) {
        let base = directory.appendingPathComponent(Self.fileName + Self.migratingSuffix).path
        for sidecar in [""] + Self.sidecars where fileManager.fileExists(atPath: base + sidecar) {
            try? fileManager.removeItem(atPath: base + sidecar)
        }
    }

    private func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }

    private func step(_ step: Step, _ temporary: URL) throws {
        try fault?(step, temporary)
    }

    // MARK: - Log

    public static let systemLog: @Sendable (String) -> Void = { message in
        #if canImport(os)
        Logger(subsystem: "mind.anima", category: "database").notice("\(message, privacy: .public)")
        #else
        print(message)
        #endif
    }
}
