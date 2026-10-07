// WidgetSnapshotBuilder.swift — arma el snapshot desde los stores vivos de la
// app (recordatorios, metas, self) y lo publica en el App Group. La app lo
// llama tras cada cambio relevante (sync proactivo, sueño, arranque) y avisa a
// WidgetKit con `reload` (WidgetCenter vive en el shell).

import Foundation

public struct WidgetSnapshotBuilder: Sendable {
    /// Tope de recordatorios en el snapshot (un widget pinta ≤ 4).
    public static let reminderLimit = 30

    private let reminders: AnimaReminderStore?
    private let otherModel: OtherModel?
    private let selfModel: SelfModel?
    private let now: @Sendable () -> Date

    public init(reminders: AnimaReminderStore?, otherModel: OtherModel?, selfModel: SelfModel?,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.reminders = reminders
        self.otherModel = otherModel
        self.selfModel = selfModel
        self.now = now
    }

    public func build() async -> WidgetSnapshot {
        let ts = now()
        var items: [WidgetSnapshot.Reminder] = []
        if let reminders {
            for reminder in await reminders.list(.upcoming, limit: Self.reminderLimit) {
                items.append(.init(id: reminder.id, text: reminder.text, fireAt: reminder.fireAt,
                                   cadence: reminder.repeatCadence, delivered: false, goalId: reminder.goalId))
            }
            // Entregados sin "Hecho" (uno-a-uno): siguen siendo de hoy hasta cerrarlos.
            for reminder in await reminders.list(.fired, limit: 10) {
                items.append(.init(id: reminder.id, text: reminder.text, fireAt: reminder.fireAt,
                                   cadence: reminder.repeatCadence, delivered: true, goalId: reminder.goalId))
            }
        }
        var goals: [WidgetSnapshot.Goal] = []
        if let otherModel {
            for goal in await otherModel.desire() {
                goals.append(.init(id: goal.id, statement: goal.statement, checkIn: goal.checkIn,
                                   streak: await otherModel.streak(goalId: goal.id),
                                   lastProgressAt: await otherModel.lastProgressAt(goalId: goal.id),
                                   lastAnsweredAt: await otherModel.lastAnsweredAt(goalId: goal.id)))
            }
        }
        let cycles = await selfModel?.cycles() ?? 0
        return WidgetSnapshot(generatedAt: ts, selfName: await selfModel?.name() ?? Birth.seed.name,
                              plasticity: Plasticity.value(cycles: cycles), nights: cycles,
                              reminders: items, goals: goals)
    }
}

/// El JSON en `<grupo>/Widgets/WidgetSnapshot.json`: escritura atómica (la
/// extensión nunca ve un archivo a medias) y lectura tolerante.
public struct WidgetSnapshotStore: Sendable {
    public static let fileName = "WidgetSnapshot.json"

    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    /// `<grupo>/Widgets` o nil sin App Group.
    public static func shared() -> WidgetSnapshotStore? {
        AppGroup.widgetsDirectory().map(WidgetSnapshotStore.init(directory:))
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        // Los widgets de bloqueo leen con el teléfono bloqueado (tras el primer desbloqueo).
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try encoder.encode(snapshot).write(to: url, options: options)
    }

    /// nil si no existe, está corrupto o es de una versión futura.
    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version <= WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }
}

/// Construye + escribe + avisa a WidgetKit. Errores de disco: se loguean, la
/// app sigue (el widget conserva el último snapshot bueno).
public actor WidgetPublisher {
    private let builder: WidgetSnapshotBuilder
    private let store: WidgetSnapshotStore
    private let reload: @Sendable () -> Void
    private let log: @Sendable (String) -> Void

    public init(builder: WidgetSnapshotBuilder, store: WidgetSnapshotStore,
                reload: @escaping @Sendable () -> Void,
                log: @escaping @Sendable (String) -> Void = DatabaseRelocation.systemLog) {
        self.builder = builder
        self.store = store
        self.reload = reload
        self.log = log
    }

    @discardableResult
    public func publish() async -> WidgetSnapshot? {
        let snapshot = await builder.build()
        do {
            try store.write(snapshot)
        } catch {
            log("widgets: no se pudo escribir el snapshot: \(error)")
            return nil
        }
        reload()
        return snapshot
    }
}
