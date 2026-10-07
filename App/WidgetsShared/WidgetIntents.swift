// WidgetIntents.swift — AppIntents de los widgets, compilados en la app Y en la
// extensión (mismo archivo, App/WidgetsShared). Los botones "Hecho" y "Sí,
// avancé" son LiveActivityIntent: iOS los ejecuta en el proceso de la APP
// (despertándola en background), que aplica la acción con el mismo
// ProactiveActionHandler de las notificaciones. Antes de nada la acción queda
// durable en la cola del App Group y el widget se repinta optimista: si por lo
// que sea corre en la extensión, la app la aplica al abrir/volver/pulso.

import AppIntents
import Foundation
import WidgetKit
import AnimaWidgetCore

/// Puente con el proceso de la app: el shell instala `apply` al lanzar. En la
/// extensión queda nil (la acción espera en la cola).
final class WidgetIntentBridge: @unchecked Sendable {
    static let shared = WidgetIntentBridge()
    private let lock = NSLock()
    private var applyHandler: (@Sendable () async -> Void)?

    /// La app drena la cola (ensureBootstrapped + handler + re-sync + snapshot).
    var apply: (@Sendable () async -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return applyHandler }
        set { lock.lock(); defer { lock.unlock() }; applyHandler = newValue }
    }

    /// Encola + repinta optimista + (si es la app) aplica ya.
    static func submit(_ action: WidgetAction) async throws {
        guard let inbox = WidgetActionInbox.shared() else { return }
        try inbox.enqueue(action)
        if let store = WidgetSnapshotStore.shared(), let snapshot = store.read() {
            try? store.write(snapshot.applying(action))
        }
        WidgetCenter.shared.reloadAllTimelines()
        if let apply = shared.apply { await apply() }
    }
}

struct CompleteReminderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Marcar recordatorio como hecho"
    static let description = IntentDescription("Cierra un recordatorio de Anima desde el widget.")
    static let isDiscoverable = false

    @Parameter(title: "Recordatorio")
    var reminderId: String

    init() {}

    init(reminderId: String) {
        self.reminderId = reminderId
    }

    func perform() async throws -> some IntentResult {
        try await WidgetIntentBridge.submit(WidgetAction(kind: .reminderDone(reminderId: reminderId)))
        return .result()
    }
}

struct ProgressCheckInIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Sí, avancé"
    static let description = IntentDescription("Responde el seguimiento de una meta desde el widget.")
    static let isDiscoverable = false

    @Parameter(title: "Meta")
    var goalId: String

    init() {}

    init(goalId: String) {
        self.goalId = goalId
    }

    func perform() async throws -> some IntentResult {
        try await WidgetIntentBridge.submit(WidgetAction(kind: .checkInProgress(goalId: goalId)))
        return .result()
    }
}

/// Centro de control / botón de Acción: abre el chat con el mic escuchando.
struct TalkToAnimaIntent: AppIntent {
    static let title: LocalizedStringResource = "Hablar con Anima"
    static let description = IntentDescription("Abre el chat de Anima con el micrófono activo.")
    static let openAppWhenRun = true

    init() {}

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(AnimaDeepLink.talk.url))
    }
}

// MARK: - Configuración del widget Meta

struct GoalEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Meta"
    static let defaultQuery = GoalEntityQuery()

    var id: String
    var statement: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(statement)")
    }
}

/// Lee las metas del snapshot (la extensión nunca abre la base).
struct GoalEntityQuery: EntityQuery {
    init() {}

    private func all() -> [GoalEntity] {
        (WidgetSnapshotStore.shared()?.read()?.goals ?? []).map { GoalEntity(id: $0.id, statement: $0.statement) }
    }

    func entities(for identifiers: [GoalEntity.ID]) async throws -> [GoalEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [GoalEntity] { all() }

    func defaultResult() async -> GoalEntity? { all().first }
}

struct SelectGoalIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Elegir meta"
    static let description = IntentDescription("La meta que muestra el widget.")

    @Parameter(title: "Meta")
    var goal: GoalEntity?

    init() {}

    init(goal: GoalEntity?) {
        self.goal = goal
    }
}
