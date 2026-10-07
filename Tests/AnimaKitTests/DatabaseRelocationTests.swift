import Foundation
import Testing
import GRDB
@testable import AnimaKit

/// La mudanza de `anima.sqlite` al App Group: jamás perder un turno.
@Suite struct DatabaseRelocationTests {

    /// Sandbox de prueba: Documents falso + contenedor de grupo falso.
    struct Sandbox {
        let root: URL
        var documents: URL { root.appendingPathComponent("Documents", isDirectory: true) }
        var group: URL { root.appendingPathComponent("Group/Database", isDirectory: true) }
        var legacy: URL { documents.appendingPathComponent("anima.sqlite") }
        var target: URL { group.appendingPathComponent("anima.sqlite") }
        var temporary: URL { group.appendingPathComponent("anima.sqlite.migrating") }
        var retired: URL { documents.appendingPathComponent("anima.sqlite.migrated") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("relocation-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"),
                                                    withIntermediateDirectories: true)
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        func relocation(group: Bool = true, protect: @escaping @Sendable (URL) -> Void = { _ in },
                        fault: (@Sendable (DatabaseRelocation.Step, URL) throws -> Void)? = nil) -> DatabaseRelocation {
            DatabaseRelocation(legacyURL: legacy, groupDirectory: group ? self.group : nil,
                               protect: protect, log: { _ in }, fault: fault)
        }

        /// Base vieja real (todas las migraciones) con turnos, memorias y metas.
        @discardableResult
        func seedLegacy(turns: Int = 40) async throws -> [String] {
            let queue = try AnimaDatabase.makeQueue(path: legacy.path)
            let store = SymbolicStore(queue: queue)
            let sid = try store.startSession()
            var texts: [String] = []
            for i in 0..<turns {
                let text = "turno \(i) — ñandú 🦤"
                texts.append(text)
                try store.append(sessionId: sid, message: i.isMultiple(of: 2) ? .user(text) : .assistant([.text(text)]))
            }
            let brain = Brain(queue: queue)
            _ = try await brain.add(MemoryCandidate(content: "Le gusta correr temprano"))
            _ = try await brain.add(MemoryCandidate(content: "Vive en Bogotá"))
            let other = OtherModel(queue: queue)
            _ = await other.ingestStated(statement: "Ahorrar 10M", desiredState: .progressCheckIn(everyDays: 1),
                                         evidence: "test")
            try queue.close()
            return texts
        }

        func turnTexts(at url: URL) throws -> [String] {
            let queue = try DatabaseQueue(path: url.path)
            defer { try? queue.close() }
            return try queue.read { db in
                try String.fetchAll(db, sql: "SELECT content_json FROM turn_event ORDER BY id")
            }
        }

        func count(_ table: String, at url: URL) throws -> Int {
            let queue = try DatabaseQueue(path: url.path)
            defer { try? queue.close() }
            return try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
        }
    }

    struct Injected: Error {}

    // MARK: - Caminos felices

    @Test func freshInstallLivesInTheGroup() throws {
        let box = try Sandbox()
        let resolution = box.relocation().resolve()
        #expect(resolution == .init(path: box.target.path, outcome: .fresh))
        #expect(box.exists(box.group))
        let queue = try AnimaDatabase.makeQueue(path: resolution.path)
        try queue.close()
        #expect(box.exists(box.target))
    }

    @Test func withoutGroupContainerStaysInDocuments() async throws {
        let box = try Sandbox()
        try await box.seedLegacy()
        let resolution = box.relocation(group: false).resolve()
        #expect(resolution == .init(path: box.legacy.path, outcome: .noGroupContainer))
        #expect(box.exists(box.legacy))
        #expect(box.relocation(group: false).targetURL == nil)
    }

    @Test func migratesVerifiesEveryRowAndRetiresWithoutDeleting() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 40)
        let before = try box.turnTexts(at: box.legacy)
        let protected = Locked<[String]>([])

        let resolution = box.relocation(protect: { url in protected.mutate { $0.append(url.lastPathComponent) } })
            .resolve()

        guard case .migrated(let rows) = resolution.outcome else {
            Issue.record("esperaba migrated, llegó \(resolution.outcome)"); return
        }
        #expect(resolution.path == box.target.path)
        #expect(rows["turn_event"] == 40)
        #expect(rows["memory"] == 2)
        #expect(rows["goal"] == 1)
        // La nueva tiene exactamente los mismos turnos, en el mismo orden.
        #expect(try box.turnTexts(at: box.target) == before)
        // La vieja NO se borra: queda como .migrated, con los mismos turnos.
        #expect(!box.exists(box.legacy))
        #expect(box.exists(box.retired))
        #expect(try box.turnTexts(at: box.retired) == before)
        #expect(!box.exists(box.temporary))
        #expect(protected.value.contains("anima.sqlite"))
        #expect(protected.value.contains("Database"))
        // La app abre la nueva con su migrador (sin pérdida) y ve los turnos.
        let queue = try AnimaDatabase.makeQueue(path: resolution.path)
        let store = SymbolicStore(queue: queue)
        let sid = try #require(try await queue.read { db in try String.fetchOne(db, sql: "SELECT id FROM session") })
        #expect(try store.visibleTurns(sessionId: sid).count == 40)
        try queue.close()
    }

    @Test func secondLaunchIsIdempotent() async throws {
        let box = try Sandbox()
        try await box.seedLegacy()
        let before = try box.turnTexts(at: box.legacy)
        _ = box.relocation().resolve()
        let again = box.relocation().resolve()
        #expect(again == .init(path: box.target.path, outcome: .alreadyMigrated))
        let third = box.relocation().resolve()
        #expect(third.outcome == .alreadyMigrated)
        #expect(try box.turnTexts(at: box.target) == before)
        let documents = try FileManager.default.contentsOfDirectory(atPath: box.documents.path).sorted()
        #expect(documents == ["anima.sqlite.in-app-group", "anima.sqlite.migrated"])
    }

    @Test func alreadyMigratedDoesNotTouchTheGroupDatabase() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 3)
        _ = box.relocation().resolve()
        // La app sigue escribiendo en la nueva…
        let queue = try AnimaDatabase.makeQueue(path: box.target.path)
        let store = SymbolicStore(queue: queue)
        try store.append(sessionId: try store.startSession(), message: .user("después de mudarse"))
        try queue.close()
        // …y un arranque posterior no la reemplaza por nada.
        #expect(box.relocation().resolve().outcome == .alreadyMigrated)
        #expect(try box.count("turn_event", at: box.target) == 4)
        #expect(try box.count("turn_event", at: box.retired) == 3)
    }

    // MARK: - Fallo a mitad

    @Test(arguments: [DatabaseRelocation.Step.prepare, .checkpoint, .copy, .verify, .protect, .install])
    func failureMidwayKeepsLegacyIntactAndRetriesNextLaunch(step failing: DatabaseRelocation.Step) async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 25)
        let before = try box.turnTexts(at: box.legacy)

        let resolution = box.relocation(fault: { step, _ in if step == failing { throw Injected() } }).resolve()

        guard case .keptLegacy = resolution.outcome else {
            Issue.record("\(failing): esperaba keptLegacy, llegó \(resolution.outcome)"); return
        }
        #expect(resolution.path == box.legacy.path)
        #expect(try box.turnTexts(at: box.legacy) == before)
        #expect(!box.exists(box.target))
        #expect(!box.exists(box.temporary))
        #expect(!box.exists(box.retired))

        // Próximo arranque sin fallo: se muda completa.
        let retry = box.relocation().resolve()
        guard case .migrated = retry.outcome else { Issue.record("reintento: \(retry.outcome)"); return }
        #expect(try box.turnTexts(at: box.target) == before)
    }

    @Test func failureRetiringLegacyStillUsesTheVerifiedCopyAndFinishesLater() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 5)
        let before = try box.turnTexts(at: box.legacy)
        let resolution = box.relocation(fault: { step, _ in if step == .retireLegacy { throw Injected() } }).resolve()
        guard case .migrated = resolution.outcome else { Issue.record("\(resolution.outcome)"); return }
        #expect(resolution.path == box.target.path)
        #expect(box.exists(box.legacy))          // no se pudo retirar: sigue ahí, intacta
        #expect(try box.turnTexts(at: box.target) == before)

        let next = box.relocation().resolve()
        #expect(next.outcome == .alreadyMigrated)
        #expect(!box.exists(box.legacy))
        #expect(try box.turnTexts(at: box.retired) == before)
    }

    @Test func copyMissingRowsIsRejected() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 10)
        let resolution = box.relocation(fault: { step, temporary in
            guard step == .verify else { return }
            let copy = try DatabaseQueue(path: temporary.path)
            try copy.write { db in try db.execute(sql: "DELETE FROM turn_event WHERE id = (SELECT MAX(id) FROM turn_event)") }
            try copy.close()
        }).resolve()
        guard case .keptLegacy(let reason) = resolution.outcome else { Issue.record("\(resolution.outcome)"); return }
        #expect(reason.contains("turn_event"))
        #expect(try box.count("turn_event", at: box.legacy) == 10)
        #expect(!box.exists(box.target))
        #expect(!box.exists(box.temporary))
    }

    @Test func corruptCopyIsRejected() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 10)
        let resolution = box.relocation(fault: { step, temporary in
            guard step == .verify else { return }
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.seek(toOffset: 0)
            handle.write(Data(repeating: 0xAB, count: 8192))
            try handle.close()
        }).resolve()
        guard case .keptLegacy = resolution.outcome else { Issue.record("\(resolution.outcome)"); return }
        #expect(try box.count("turn_event", at: box.legacy) == 10)
        #expect(!box.exists(box.target))
    }

    @Test func extraTableInCopyIsRejected() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 2)
        let resolution = box.relocation(fault: { step, temporary in
            guard step == .verify else { return }
            let copy = try DatabaseQueue(path: temporary.path)
            try copy.write { db in try db.execute(sql: "CREATE TABLE intruder (x INTEGER)") }
            try copy.close()
        }).resolve()
        guard case .keptLegacy(let reason) = resolution.outcome else { Issue.record("\(resolution.outcome)"); return }
        #expect(reason.contains("schemaMismatch") || reason.contains("esquema"))
    }

    // MARK: - Bordes

    @Test func staleTemporaryFromAPreviousCrashIsDiscarded() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 7)
        try FileManager.default.createDirectory(at: box.group, withIntermediateDirectories: true)
        try Data("basura de un arranque que murió a mitad".utf8).write(to: box.temporary)
        try Data("wal viejo".utf8).write(to: URL(fileURLWithPath: box.temporary.path + "-journal"))
        let resolution = box.relocation().resolve()
        guard case .migrated = resolution.outcome else { Issue.record("\(resolution.outcome)"); return }
        #expect(try box.count("turn_event", at: box.target) == 7)
        #expect(!box.exists(box.temporary))
    }

    @Test func pendingWALFramesTravelWithTheCopy() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 4)
        // Un escritor en WAL sin checkpoint, con la conexión aún abierta.
        let writer = try DatabaseQueue(path: box.legacy.path)
        try await writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint=0")
        }
        let store = SymbolicStore(queue: writer)
        try store.append(sessionId: try store.startSession(), message: .user("solo en el WAL"))
        #expect(box.exists(URL(fileURLWithPath: box.legacy.path + "-wal")))

        let resolution = box.relocation().resolve()
        guard case .migrated(let rows) = resolution.outcome else { Issue.record("\(resolution.outcome)"); return }
        #expect(rows["turn_event"] == 5)
        #expect(try box.count("turn_event", at: box.target) == 5)
        try writer.close()
    }

    @Test func neverOverwritesAPreviouslyRetiredFile() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 3)
        try Data("retiro anterior".utf8).write(to: box.retired)
        let resolution = box.relocation().resolve()
        guard case .migrated = resolution.outcome else { Issue.record("\(resolution.outcome)"); return }
        #expect(try String(contentsOf: box.retired, encoding: .utf8) == "retiro anterior")
        let second = URL(fileURLWithPath: box.retired.path + ".2")
        #expect(try box.count("turn_event", at: second) == 3)
    }

    @Test func unwritableGroupKeepsLegacy() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 2)
        // El "directorio" del grupo es un archivo: no se puede crear ni copiar ahí.
        try FileManager.default.createDirectory(at: box.group.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: box.group)
        let resolution = box.relocation().resolve()
        guard case .keptLegacy = resolution.outcome else { Issue.record("\(resolution.outcome)"); return }
        #expect(resolution.path == box.legacy.path)
        #expect(try box.count("turn_event", at: box.legacy) == 2)
    }

    @Test func freshInstallWithUnwritableGroupFallsBackToDocuments() throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: box.group.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: box.group)
        let resolution = box.relocation().resolve()
        guard case .keptLegacy = resolution.outcome else { Issue.record("\(resolution.outcome)"); return }
        #expect(resolution.path == box.legacy.path)
    }

    @Test func errorsDescribeThemselves() {
        #expect(DatabaseRelocation.RelocationError.integrity("x").errorDescription?.contains("integrity") == true)
        #expect(DatabaseRelocation.RelocationError.schemaMismatch.errorDescription?.contains("esquema") == true)
        #expect(DatabaseRelocation.RelocationError.rowCountMismatch(table: "goal", source: 1, copy: 0)
            .errorDescription?.contains("goal") == true)
        #expect(DatabaseRelocation.RelocationError.groupUnavailable.errorDescription?.contains("vacía") == true)
        DatabaseRelocation.systemLog("db-relocation: prueba de log")
        #expect(AppGroup.identifier == "group.com.joshuamoreno1.anima.widgets")
        _ = AppGroup.databaseDirectory()
        _ = AppGroup.widgetsDirectory()
    }
}

extension DatabaseRelocationTests {
    @Test func copyFromWALSourceLandsInRollbackJournalMode() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 1)
        let writer = try DatabaseQueue(path: box.legacy.path)
        try await writer.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode=WAL") }
        try writer.close()
        _ = box.relocation().resolve()
        let copy = try DatabaseQueue(path: box.target.path)
        let mode = try await copy.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        #expect(mode == "delete")
        try copy.close()
    }
}

// MARK: - Grupo que desaparece, sidecars huérfanos y purga del .migrated

extension DatabaseRelocationTests {
    @Test func groupVanishedAfterMigratingNeverOpensAnEmptyDatabase() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 6)
        _ = box.relocation().resolve()

        let resolution = box.relocation(group: false).resolve()
        #expect(resolution.outcome == .groupUnavailable)
        #expect(throws: DatabaseRelocation.RelocationError.groupUnavailable) { try resolution.openablePath() }
        // Ni base vacía en Documents ni la .migrated tocada: nada que esconder después.
        #expect(!box.exists(box.legacy))
        #expect(try box.count("turn_event", at: box.retired) == 6)

        // El grupo vuelve: la base del grupo, intacta, y sin .migrated.2.
        let back = box.relocation().resolve()
        #expect(back.outcome == .alreadyMigrated)
        #expect(try back.openablePath() == box.target.path)
        #expect(try box.count("turn_event", at: box.target) == 6)
        #expect(!box.exists(URL(fileURLWithPath: box.retired.path + ".2")))
    }

    @Test func groupVanishedAfterAFreshInstallInTheGroupIsAlsoUnavailable() throws {
        let box = try Sandbox()
        #expect(box.relocation().resolve().outcome == .fresh)
        let resolution = box.relocation(group: false).resolve()
        #expect(resolution.outcome == .groupUnavailable)
        #expect(!box.exists(box.legacy))
    }

    @Test func retiredFileAloneAlsoMarksTheGroupAsHome() throws {
        let box = try Sandbox()
        try Data("retirada".utf8).write(to: box.retired)
        #expect(box.relocation(group: false).resolve().outcome == .groupUnavailable)
    }

    @Test func noOrphanSidecarsOfTheTemporaryAfterMigratingFromWAL() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 2)
        let writer = try DatabaseQueue(path: box.legacy.path)
        try await writer.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode=WAL") }
        try writer.close()
        guard case .migrated = box.relocation().resolve().outcome else { Issue.record("no migró"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.group.path) == ["anima.sqlite"])
    }

    @Test func retiredCopyIsPurgedOnlyAfterEnoughGoodOpensInLaterLaunches() async throws {
        let box = try Sandbox()
        try await box.seedLegacy(turns: 3)
        try Data("retiro anterior".utf8).write(to: box.retired)
        let migration = box.relocation().resolve()
        guard case .migrated = migration.outcome else { Issue.record("\(migration.outcome)"); return }
        // La apertura del arranque de la mudanza no cuenta.
        box.relocation().confirmOpened(migration)
        #expect(box.relocation().opens() == 0)

        for launch in 1...DatabaseRelocation.purgeAfterOpens {
            let resolution = box.relocation().resolve()
            #expect(resolution.outcome == .alreadyMigrated)
            #expect(box.exists(box.retired), "arranque \(launch): aún no se purga")
            #expect(box.relocation().retiredFiles().count == 2)
            box.relocation().confirmOpened(resolution)
        }
        #expect(box.relocation().opens() == DatabaseRelocation.purgeAfterOpens)

        let purged = box.relocation().resolve()
        #expect(purged.outcome == .alreadyMigrated)
        #expect(box.relocation().retiredFiles().isEmpty)
        #expect(try box.count("turn_event", at: box.target) == 3)
        // Purgada la copia, la marca sigue diciendo dónde vive la base.
        #expect(box.relocation(group: false).resolve().outcome == .groupUnavailable)
    }

    @Test func opensAreOnlyCountedForTheGroupDatabase() throws {
        let box = try Sandbox()
        let legacyOnly = box.relocation(group: false).resolve()
        box.relocation(group: false).confirmOpened(legacyOnly)
        #expect(!box.exists(URL(fileURLWithPath: box.legacy.path + DatabaseRelocation.groupMarkerSuffix)))
        let fresh = box.relocation().resolve()
        box.relocation().confirmOpened(fresh)
        #expect(box.relocation().opens() == 0)
    }
}
