// DesireEngine.swift — el pulso del deseo (§5.8). Actor. pulse() reconcilia
// brechas: para cada Goal que MOTIVA (stated, o inferred confirmado) evalúa su
// Observable (0 LLM); si hay gap genera un drive, rankea por precedencia+staleness,
// toma el top y redacta con Haiku (.desirePulse) una Intention concreta que
// aparece como mensaje proactivo del agente en el chat.
//
// Contrato del spec (no opcional):
//  - El engine NO puede crear Goals: solo lee OtherModel.desire() (el tipo lo
//    garantiza; aquí no hay API de escritura de Goals).
//  - Presupuesto duro: ≤4 pulsos/día (persistido, reloj inyectable); el excedente
//    espera. Cooldown por goal: no proponer lo mismo 2 veces en <48h.
//  - Log auditable: cada Intention persiste con goal_id NOT NULL (eval #4).

import Foundation
import GRDB

/// Una brecha detectada: la realidad no avanza hacia la meta.
public struct Lack: Sendable, Equatable {
    public var goal: Goal
    public var reading: ObservableReading
}

/// El log de una propuesta proactiva. outcome lo alimentan los botones del chat.
public struct Intention: Sendable, Equatable, Identifiable, Codable {
    public enum Outcome: String, Sendable, Codable, Equatable {
        case pending, accepted, dismissed, ignored
    }
    public var id: String
    public var goalId: String
    public var observablesJSON: String
    public var gap: String
    public var proposedText: String
    public var outcome: Outcome
    public var createdAt: Date
}

public actor DesireEngine {
    private let otherModel: OtherModel
    private let environment: ObservableEnvironment
    private let queue: DatabaseQueue
    private let provider: Provider
    private let router: ModelRouter
    private let authMode: AuthMode
    private let token: String
    private let store: SymbolicStore?
    private let telemetry: Telemetry?
    private let now: @Sendable () -> Date
    private let dailyBudget: Int
    private let cooldown: TimeInterval

    /// ≤4 pulsos/día (§5.8) y cooldown de 48h por goal.
    public init(otherModel: OtherModel,
                environment: ObservableEnvironment,
                queue: DatabaseQueue,
                provider: Provider,
                router: ModelRouter,
                authMode: AuthMode,
                token: String,
                store: SymbolicStore? = nil,
                telemetry: Telemetry? = nil,
                dailyBudget: Int = 4,
                cooldown: TimeInterval = 48 * 3600,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.otherModel = otherModel
        self.environment = environment
        self.queue = queue
        self.provider = provider
        self.router = router
        self.authMode = authMode
        self.token = token
        self.store = store
        self.telemetry = telemetry
        self.dailyBudget = dailyBudget
        self.cooldown = cooldown
        self.now = now
    }

    // MARK: - El pulso

    /// Un pulso: evalúa gaps (gratis), y si hay presupuesto y un gap fuera de
    /// cooldown, produce como máximo UNA Intention. Devuelve las producidas (0 o 1).
    @discardableResult
    public func pulse(sessionId: SessionID? = nil) async throws -> [Intention] {
        let gaps = await self.gaps()
        guard !gaps.isEmpty else { return [] }

        // Cooldown por goal (§5.8): nada propuesto en <48h.
        let eligible = gaps.filter { !inCooldown(goalId: $0.goal.id) }
        guard let top = rank(eligible).first else { return [] }

        // Presupuesto duro: el 5º pulso del día no corre; el gap espera.
        guard pulsesToday() < dailyBudget else { return [] }

        let intention = try await drive(top, sessionId: sessionId)
        return [intention]
    }

    /// gap() del spec: brechas de todos los goals que motivan (0 LLM).
    public func gaps() async -> [Lack] {
        var out: [Lack] = []
        for goal in await otherModel.desire() {
            let reading = await goal.desiredState.evaluate(in: environment)
            if !reading.satisfied { out.append(Lack(goal: goal, reading: reading)) }
        }
        return out
    }

    private func rank(_ lacks: [Lack]) -> [Lack] {
        lacks.sorted { a, b in
            if a.goal.source.precedence != b.goal.source.precedence {
                return a.goal.source.precedence < b.goal.source.precedence
            }
            if a.goal.priority != b.goal.priority { return a.goal.priority > b.goal.priority }
            return a.goal.updatedAt < b.goal.updatedAt
        }
    }

    // MARK: - drive: redactar la Intention (Haiku)

    private func drive(_ lack: Lack, sessionId: SessionID?) async throws -> Intention {
        // Contexto barato para hacer la propuesta concreta (huecos del calendario).
        let slots = await environment.freeSlots(minMinutes: 45, withinDays: 7)
        let slotHint = slots.first.map { Self.describeSlot($0) } ?? "sin un hueco claro; sugiere cómo abrirlo"

        let user = """
        Meta del dueño: "\(lack.goal.statement)"
        Estado observado: \(lack.reading.detail)
        Hueco disponible: \(slotHint)

        Redacta UNA propuesta proactiva breve (1-2 frases, en español, tono cercano y directo)
        que ayude al dueño a avanzar hacia esa meta. Ofrece una acción concreta y termina
        preguntando si la hace. Devuelve SOLO el texto de la propuesta, sin comillas.
        """
        let text = try await complete(system: Self.drivePrompt, user: user, maxOutputTokens: 400)
        let proposed = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallbackText(lack)
            : text.trimmingCharacters(in: .whitespacesAndNewlines)

        let intention = persist(lack: lack, proposedText: proposed)
        // Persiste como turno del agente marcado proactive (canónico: entra al
        // contexto del próximo turno). La distinción visual la lleva el chat vía
        // el log de Intentions.
        if let store, let sessionId {
            try? store.append(sessionId: sessionId, message: .assistant([.text(proposed)]))
        }
        recordPulse()
        return intention
    }

    private func fallbackText(_ lack: Lack) -> String {
        "Sobre '\(lack.goal.statement)': \(lack.reading.detail). ¿Quieres que te ayude a avanzar?"
    }

    // MARK: - Log de Intentions (goal_id NOT NULL = eval #4)

    private func persist(lack: Lack, proposedText: String) -> Intention {
        let id = UUID().uuidString
        let ts = now()
        let observables = ObservableLog(predicate: lack.goal.desiredState, detail: lack.reading.detail)
        let observablesJSON = String(data: (try? JSONEncoder().encode(observables)) ?? Data(), encoding: .utf8) ?? "{}"
        try? queue.write { db in
            try db.execute(sql: """
                INSERT INTO intention (id, goal_id, observables_json, gap, proposed_text, outcome, created_at)
                VALUES (?,?,?,?,?, 'pending', ?)
                """, arguments: [id, lack.goal.id, observablesJSON, lack.reading.detail, proposedText,
                                 ts.timeIntervalSince1970])
        }
        return Intention(id: id, goalId: lack.goal.id, observablesJSON: observablesJSON,
                         gap: lack.reading.detail, proposedText: proposedText,
                         outcome: .pending, createdAt: ts)
    }

    /// Intentions aún sin resolver (para pintarlas como mensajes proactivos).
    public func pendingIntentions() -> [Intention] {
        (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM intention WHERE outcome='pending' ORDER BY created_at ASC")
                .map(Self.intention(from:))
        }) ?? []
    }

    public func allIntentions(limit: Int = 200) -> [Intention] {
        (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM intention ORDER BY created_at DESC LIMIT ?", arguments: [limit])
                .map(Self.intention(from:))
        }) ?? []
    }

    /// El chat alimenta el outcome (aceptar/descartar). `ignored` se puede aplicar
    /// en barrido a las viejas sin respuesta.
    public func recordOutcome(id: String, outcome: Intention.Outcome) {
        try? queue.write { db in
            try db.execute(sql: "UPDATE intention SET outcome=? WHERE id=?",
                           arguments: [outcome.rawValue, id])
        }
    }

    // MARK: - Presupuesto y cooldown (reloj inyectable)

    public func pulsesToday() -> Int {
        let day = Self.dayString(now())
        return (try? queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM desire_pulse WHERE day=?", arguments: [day])
        }).flatMap { $0 } ?? 0
    }

    private func recordPulse() {
        let ts = now()
        try? queue.write { db in
            try db.execute(sql: "INSERT INTO desire_pulse (ts, day) VALUES (?,?)",
                           arguments: [ts.timeIntervalSince1970, Self.dayString(ts)])
        }
    }

    private func inCooldown(goalId: String) -> Bool {
        let cutoff = now().addingTimeInterval(-cooldown).timeIntervalSince1970
        let recent = (try? queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM intention WHERE goal_id=? AND created_at > ?",
                             arguments: [goalId, cutoff])
        }).flatMap { $0 } ?? 0
        return recent > 0
    }

    // MARK: - Provider (Haiku, single-shot — patrón del Consolidator)

    private func complete(system: String, user: String, maxOutputTokens: Int) async throws -> String {
        var route = router.route(.desirePulse)
        route = ModelRoute(model: route.model,
                           effort: ModelParamPolicy.policy(for: route.model).allowsEffort ? route.effort : nil,
                           maxTokens: min(route.maxTokens, maxOutputTokens))
        let opts = CallOpts(route: route, api: router.api, authMode: authMode,
                            token: token, systemPromptBase: system)
        let response = try await provider.completeCollecting(
            AssembledContext(messages: [.user(user)]), tools: [], opts: opts)
        if let telemetry {
            try? telemetry.record(sessionId: "desire", turnClass: .desirePulse, model: route.model,
                                  usage: response.usage, toolCalls: 0, retries: 0)
        }
        return response.content.compactMap { block in
            if case .text(let t) = block { return t } else { return nil }
        }.joined()
    }

    static func describeSlot(_ interval: DateInterval) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_CO")
        df.dateFormat = "EEEE d 'a las' HH:mm"
        let minutes = Int(interval.duration / 60)
        return "\(df.string(from: interval.start)) (\(minutes)min)"
    }

    static func dayString(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func intention(from row: Row) -> Intention {
        Intention(
            id: row["id"],
            goalId: row["goal_id"],
            observablesJSON: row["observables_json"] ?? "{}",
            gap: row["gap"] ?? "",
            proposedText: row["proposed_text"] ?? "",
            outcome: Intention.Outcome(rawValue: row["outcome"]) ?? .pending,
            createdAt: Date(timeIntervalSince1970: row["created_at"]))
    }
}

private struct ObservableLog: Codable {
    let predicate: ObservablePredicate
    let detail: String
}

extension DesireEngine {
    static let drivePrompt = """
    Eres el motor de deseo de un asistente personal. Reconcilias brechas entre las metas del \
    dueño y lo que su teléfono observa. Propones acciones concretas y respetuosas; nunca \
    inventas metas ni presionas. Respondes SOLO con el texto de una propuesta breve en español.
    """
}
