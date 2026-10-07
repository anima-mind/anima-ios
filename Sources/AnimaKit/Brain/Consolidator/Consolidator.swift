// Consolidator.swift — el sueño (§5.4). Actor. Un ciclo:
//   a. saliencia   — determinístico: candidatos no consolidados del inbox
//   b. destilado   — Haiku (.distill): hechos atómicos estructurados (JSON)
//   c. escritura   — por candidato ADD/UPDATE/INVALIDATE/NOOP contra el brain
//   d. reconsolid. — Haiku (.reconsolidation): memorias frecuentes/contradichas
//   e. reflection  — Haiku (.consolidation): síntesis del ciclo → cycle_log
//
// Todo el ciclo es REANUDABLE: cada etapa hace checkpoint en GRDB. Si el
// BGProcessingTask muere a mitad, el próximo retoma donde iba. Los prompts piden
// salida JSON estricta y el parseo es tolerante (extrae el primer bloque JSON).

import Foundation
import GRDB

public actor Consolidator {

    public struct CycleReport: Sendable, Equatable, Codable {
        public var cycle: Int
        public var distilled: Int
        public var added: Int
        public var updated: Int
        public var invalidated: Int
        public var noop: Int
        public var reconsolidated: Int
        public var reflectionSummary: String
        public var completed: Bool
        /// Candidatos que el DistillGuard rechazó (eco/meta/pregunta), con razón en el cycle_log.
        public var rejected: Int = 0
    }

    /// Etapas ordenadas del ciclo (persistidas para reanudar).
    enum Stage: String, Codable {
        case pending, salient, distilled, written, reconsolidated, reflected, restructured, goalsExtracted, done
        var order: Int {
            switch self {
            case .pending: return 0
            case .salient: return 1
            case .distilled: return 2
            case .written: return 3
            case .reconsolidated: return 4
            case .reflected: return 5
            case .restructured: return 6
            case .goalsExtracted: return 7
            case .done: return 8
            }
        }
    }

    private let brain: Brain
    private let queue: DatabaseQueue
    /// Córtex por clase de turno (§4.9): en Híbrido/Solo teléfono el ciclo corre
    /// en el modelo local — gratis y sin red.
    private let selector: ProviderSelector
    private let telemetry: Telemetry?
    private let cycleTokenBudget: Int
    // Fase 3: el reflection propone cambios al self (§5.5); la restructure queue del
    // RealRegister (§5.6) se procesa a lecciones y los patrones quedan resueltos.
    private let selfModel: SelfModel?
    private let realRegister: RealRegister?
    // Fase 4 (§5.8): la extracción de Stated Goals es una etapa nueva del ciclo; el
    // reflection también puede proponer metas inferred (siempre pending_confirmation).
    private let otherModel: OtherModel?

    /// Init de un solo córtex Claude (comportamiento previo a §4.9).
    public init(brain: Brain, queue: DatabaseQueue, provider: Provider, router: ModelRouter,
                authMode: AuthMode, token: String, telemetry: Telemetry? = nil,
                cycleTokenBudget: Int = 8000,
                selfModel: SelfModel? = nil, realRegister: RealRegister? = nil,
                otherModel: OtherModel? = nil) {
        self.init(brain: brain, queue: queue,
                  selector: .claudeOnly(provider: provider, router: router, authMode: authMode, token: token),
                  telemetry: telemetry, cycleTokenBudget: cycleTokenBudget,
                  selfModel: selfModel, realRegister: realRegister, otherModel: otherModel)
    }

    /// Init por modo de operación (§4.9): el selector decide dónde corre el sueño.
    public init(brain: Brain, queue: DatabaseQueue, selector: ProviderSelector,
                telemetry: Telemetry? = nil, cycleTokenBudget: Int = 8000,
                selfModel: SelfModel? = nil, realRegister: RealRegister? = nil,
                otherModel: OtherModel? = nil) {
        self.brain = brain
        self.queue = queue
        self.selector = selector
        self.telemetry = telemetry
        self.cycleTokenBudget = cycleTokenBudget
        self.selfModel = selfModel
        self.realRegister = realRegister
        self.otherModel = otherModel
    }

    // MARK: - Ciclo

    /// Ejecuta (o reanuda) un ciclo. `interrupting` se evalúa tras cada etapa con
    /// el nombre de la etapa recién completada; si devuelve true, corta limpio en
    /// frontera de etapa (modela el expirationHandler del BGProcessingTask). El
    /// próximo `cycle()` retoma donde iba.
    /// Ciclo en curso: el actor es reentrante en cada `await`, así que dos
    /// disparadores simultáneos (BGTask + fallback foreground + "Simular una
    /// noche") se coalescen en UNO — sin esto ambos corren el mismo n y la
    /// maduración del self queda indeterminada.
    private var inFlight: Task<CycleReport, Error>?

    @discardableResult
    public func cycle(interrupting shouldStop: (@Sendable (String) -> Bool)? = nil) async throws -> CycleReport {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.runCycle(interrupting: shouldStop) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func runCycle(interrupting shouldStop: (@Sendable (String) -> Bool)?) async throws -> CycleReport {
        // Fail-closed (§5.5): las aprobaciones vencidas expiran a Rejected antes de nada.
        _ = await selfModel?.expireStale()
        let (n, startStage) = try currentCycle()
        var stage = startStage

        func advance(to next: Stage) throws -> Bool {
            try setStage(cycle: n, stage: next)
            stage = next
            return shouldStop?(next.rawValue) ?? false
        }

        if stage.order < Stage.salient.order {
            try salience(cycle: n)
            if try advance(to: .salient) { return try report(cycle: n, completed: false) }
        }
        if stage.order < Stage.distilled.order {
            try await distill(cycle: n)
            if try advance(to: .distilled) { return try report(cycle: n, completed: false) }
        }
        if stage.order < Stage.written.order {
            try await writeStage(cycle: n)
            if try advance(to: .written) { return try report(cycle: n, completed: false) }
        }
        if stage.order < Stage.reconsolidated.order {
            try await reconsolidateStage(cycle: n)
            if try advance(to: .reconsolidated) { return try report(cycle: n, completed: false) }
        }
        if stage.order < Stage.reflected.order {
            try await reflectStage(cycle: n)
            if try advance(to: .reflected) { return try report(cycle: n, completed: false) }
        }
        if stage.order < Stage.restructured.order {
            try await restructureStage(cycle: n)
            if try advance(to: .restructured) { return try report(cycle: n, completed: false) }
        }
        if stage.order < Stage.goalsExtracted.order {
            try await extractGoalsStage(cycle: n)
            if try advance(to: .goalsExtracted) { return try report(cycle: n, completed: false) }
        }
        try finish(cycle: n)
        // El ciclo exitoso madura la plasticidad del self (§5.5): n += 1.
        await selfModel?.recordSuccessfulCycle()
        return try report(cycle: n, completed: true)
    }

    // MARK: - a. Saliencia (determinístico, 0 LLM)

    private func salience(cycle: Int) throws {
        try queue.write { db in
            try db.execute(sql: """
                UPDATE consolidation_inbox SET cycle=?
                WHERE consolidated_at IS NULL AND cycle IS NULL
                """, arguments: [cycle])
        }
    }

    // MARK: - b. Destilado (Haiku)

    private func distill(cycle: Int) async throws {
        let texts = try inboxTexts(cycle: cycle)
        guard !texts.isEmpty else { return }

        let joined = texts.enumerated().map { "(\($0.offset + 1)) \($0.element)" }.joined(separator: "\n")
        let user = "Mensajes recientes del dueño:\n\(joined)\n\nDevuelve SOLO el arreglo JSON."
        let text = try await complete(.distill, system: Self.distillPrompt, user: user, maxOutputTokens: cycleTokenBudget)
        let facts = Self.decode([DistilledFact].self, from: text) ?? []
        try persistDistilled(facts, cycle: cycle)
    }

    private func inboxTexts(cycle: Int) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT text FROM consolidation_inbox
                WHERE cycle=? AND consolidated_at IS NULL ORDER BY created_at ASC
                """, arguments: [cycle])
        }
    }

    private func persistDistilled(_ facts: [DistilledFact], cycle: Int) throws {
        try queue.write { db in
            var idx = 0
            for fact in facts {
                let candidate = fact.candidate(source: "cycle:\(cycle)")
                guard !candidate.content.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let json = String(data: (try? JSONEncoder().encode(candidate)) ?? Data(), encoding: .utf8) ?? "{}"
                try db.execute(sql: """
                    INSERT OR REPLACE INTO cycle_distilled (cycle, idx, candidate_json, decided, decision)
                    VALUES (?,?,?,0,NULL)
                    """, arguments: [cycle, idx, json])
                idx += 1
            }
        }
    }

    // MARK: - c. Escritura (por candidato: ADD/UPDATE/INVALIDATE/NOOP)

    private func writeStage(cycle: Int) async throws {
        let pending = try pendingDistilled(cycle: cycle)
        guard !pending.isEmpty else { return }
        let selfName = await selfModel?.name()
        let sourceTurns = try inboxTexts(cycle: cycle)
        for item in pending {
            // Guard determinista (FIX B): preguntas, meta del asistente y ecos jamás
            // llegan al Brain; quedan auditables en cycle_distilled y el cycle_log.
            if let rejection = DistillGuard.reject(item.candidate.content, selfName: selfName,
                                                   sourceTurns: sourceTurns) {
                try markDecided(cycle: cycle, idx: item.idx, decision: Self.rejectedPrefix + rejection.rawValue)
                continue
            }
            let similar = try await brain.similar(to: item.candidate.content, limit: 5)
            let directive: WriteDirective
            let label: String
            if similar.isEmpty {
                directive = .add(item.candidate)
                label = "ADD"
            } else {
                let decision = try await decide(candidate: item.candidate, against: similar)
                directive = decision.directive
                label = decision.label
            }
            _ = try await brain.write(directive, cycle: cycle)
            try markDecided(cycle: cycle, idx: item.idx, decision: label)
        }
    }

    private func pendingDistilled(cycle: Int) throws -> [(idx: Int, candidate: MemoryCandidate)] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT idx, candidate_json FROM cycle_distilled
                WHERE cycle=? AND decided=0 ORDER BY idx ASC
                """, arguments: [cycle]).compactMap { row in
                let idx: Int = row["idx"]
                let json: String = row["candidate_json"]
                guard let data = json.data(using: .utf8),
                      let candidate = try? JSONDecoder().decode(MemoryCandidate.self, from: data) else { return nil }
                return (idx, candidate)
            }
        }
    }

    private func decide(candidate: MemoryCandidate, against similar: [MemoryRecord]) async throws -> (directive: WriteDirective, label: String) {
        let listing = similar.enumerated()
            .map { "- id=\($0.element.id) :: \($0.element.content)" }
            .joined(separator: "\n")
        let user = """
        Candidato nuevo: "\(candidate.content)"
        Memorias existentes similares:
        \(listing)

        Decide una acción y devuelve SOLO el objeto JSON.
        """
        let text = try await complete(.consolidation, system: Self.decisionPrompt, user: user, maxOutputTokens: 512)
        guard let dto = Self.decode(DecisionDTO.self, from: text) else {
            return (.add(candidate), "ADD")
        }
        switch dto.decision.uppercased() {
        case "UPDATE":
            if let target = dto.target_id, similar.contains(where: { $0.id == target }) {
                return (.update(target, candidate, reason: dto.reason ?? "refinada por reconsolidación"), "UPDATE")
            }
            return (.add(candidate), "ADD")
        case "INVALIDATE":
            if let target = dto.target_id, similar.contains(where: { $0.id == target }) {
                return (.invalidate(target, reason: dto.reason ?? "contradicha por corrección explícita"), "INVALIDATE")
            }
            return (.noop, "NOOP")
        case "NOOP":
            return (.noop, "NOOP")
        default:
            return (.add(candidate), "ADD")
        }
    }

    // MARK: - d. Reconsolidación (Haiku)

    private func reconsolidateStage(cycle: Int) async throws {
        let since = lastCycleAt() ?? .distantPast
        var targets = Set(try await brain.contradicted(since: since))
        for id in try await brain.frequentlyUsed(since: since, minCount: 2) { targets.insert(id) }
        guard !targets.isEmpty else { return }

        for id in targets {
            guard let record = try await brain.record(id), record.isValid else { continue }
            let user = """
            Memoria a reconsiderar (id=\(record.id)): "\(record.content)"
            ¿Sigue vigente? Si necesita ajuste, devuelve el contenido corregido.
            Devuelve SOLO el objeto JSON.
            """
            let text = try await complete(.reconsolidation, system: Self.reconsolidationPrompt, user: user, maxOutputTokens: 512)
            guard let dto = Self.decode(RevisionDTO.self, from: text) else { continue }
            switch (dto.action ?? "keep").lowercased() {
            case "invalidate":
                try await brain.invalidate(id: record.id, reason: dto.reason ?? "invalidada en reconsolidación")
            case "revise":
                let revision = Revision(content: dto.content ?? record.content,
                                        importance: dto.importance ?? record.importance,
                                        reason: dto.reason ?? "revisada en reconsolidación")
                _ = try await brain.reconsolidate(id: record.id, revision: revision, cycle: cycle)
            default:
                break
            }
        }
    }

    // MARK: - e. Reflection (Haiku)

    private func reflectStage(cycle: Int) async throws {
        let added = try addedMemories(cycle: cycle)
        let changed = try decisionCounts(cycle: cycle)
        let touched = changed.filter { !$0.key.hasPrefix(Self.rejectedPrefix) }.values.reduce(0, +)
        guard touched > 0 || !added.isEmpty else {
            try persistReflection(cycle: cycle, summary: "", insights: [])
            return
        }
        let listing = added.prefix(20).map { "- \($0.content)" }.joined(separator: "\n")
        let user = """
        En este ciclo se consolidaron estas memorias:
        \(listing.isEmpty ? "(ninguna nueva)" : listing)
        \(await existingGoalsBlock())
        Resume en una frase qué aprendiste sobre el dueño y lista los insights de alto nivel.
        Devuelve SOLO el objeto JSON.
        """
        let text = try await complete(.consolidation, system: Self.reflectionPrompt, user: user, maxOutputTokens: 1024)
        let dto = Self.decode(ReflectionDTO.self, from: text)
        let summary = dto?.summary ?? ""
        let selfName = await selfModel?.name()
        var insights: [String] = []
        var rejectedInsights: [RejectedDTO] = []
        for insight in dto?.insights ?? [] where !insight.trimmingCharacters(in: .whitespaces).isEmpty {
            if let rejection = DistillGuard.reject(insight, selfName: selfName) {
                rejectedInsights.append(RejectedDTO(content: insight, reason: rejection.rawValue))
            } else {
                insights.append(insight)
            }
        }
        for insight in insights {
            _ = try await brain.add(MemoryCandidate(content: insight, kind: .reflection, importance: 6,
                                                    source: "cycle:\(cycle)"), cycle: cycle)
        }
        // Propuestas al SelfModel (§5.5): cada una pasa por el gate de plasticidad;
        // las identitarias en adolescencia/madurez caen a PendingOtherApproval.
        if let selfModel {
            let proposals = (dto?.self_proposals ?? []).compactMap { p -> SelfProposal? in
                guard let field = SelfProposal.Field(rawValue: p.field),
                      !p.value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return SelfProposal(field: field, value: p.value,
                                    rationale: p.rationale ?? "propuesta del reflection del ciclo",
                                    origin: .reflection)
            }
            if !proposals.isEmpty { _ = await selfModel.reflect(proposals) }
        }
        // Metas inferred (§5.8): nacen SIEMPRE pending_confirmation → no motivan
        // nada hasta que el dueño las confirme en el inbox.
        if let otherModel {
            for inferred in dto?.inferred_goals ?? [] {
                guard !inferred.statement.trimmingCharacters(in: .whitespaces).isEmpty,
                      let predicate = inferred.predicate?.toPredicate() else { continue }
                _ = await otherModel.infer(statement: inferred.statement,
                                           desiredState: predicate,
                                           evidence: inferred.rationale ?? "inferida por el reflection del ciclo",
                                           priority: inferred.priority ?? 5)
            }
        }
        try persistReflection(cycle: cycle, summary: summary, insights: insights, extraRejected: rejectedInsights)
    }

    // MARK: - f. Restructures (§5.6): la restructure queue → lecciones en el brain

    private func restructureStage(cycle: Int) async throws {
        guard let realRegister else { return }
        let requests = await realRegister.demand()
        guard !requests.isEmpty else { return }
        for req in requests {
            let onTarget = req.target.map { " sobre '\($0)'" } ?? ""
            let content = "Lección: la tool '\(req.toolName)' falla de forma repetida con '\(req.errorClass)'\(onTarget) "
                + "(insistió \(req.count) veces). Cambiar de aproximación en lugar de repetir la misma llamada."
            _ = try await brain.write(.add(MemoryCandidate(content: content, kind: .lesson, importance: 7,
                                                           source: "real:\(req.patternKey)")), cycle: cycle)
            await realRegister.resolve(patternKey: req.patternKey)
        }
    }

    // MARK: - g. Extracción de Stated Goals (§5.8, Haiku)

    /// Detecta declaraciones de meta del dueño en las sesiones del ciclo ("quiero
    /// X", "mi meta es Y") → goals stated (motivan de inmediato) con evidencia. El
    /// upsert por statement de OtherModel hace la etapa idempotente al reanudar.
    private func extractGoalsStage(cycle: Int) async throws {
        guard let otherModel else { return }
        let texts = try inboxTexts(cycle: cycle)
        guard !texts.isEmpty else { return }
        let joined = texts.enumerated().map { "(\($0.offset + 1)) \($0.element)" }.joined(separator: "\n")
        let user = """
        Mensajes del dueño en el ciclo:
        \(joined)
        \(await existingGoalsBlock())
        Devuelve SOLO el arreglo JSON de metas declaradas NUEVAS.
        """
        let text = try await complete(.consolidation, system: Self.goalsPrompt, user: user, maxOutputTokens: 1024)
        let goals = Self.decode([StatedGoalDTO].self, from: text) ?? []
        for goal in goals {
            guard !goal.statement.trimmingCharacters(in: .whitespaces).isEmpty,
                  let predicate = goal.predicate?.toPredicate() else { continue }
            _ = await otherModel.ingestStated(statement: goal.statement,
                                              desiredState: predicate,
                                              evidence: goal.evidence ?? "",
                                              priority: goal.priority ?? 5)
        }
    }

    /// Batch 8 #5: las metas que ya existen van al prompt (extracción y
    /// reflection) — el modelo no las repite ni reformuladas. El dedupe
    /// determinista de OtherModel es la red de seguridad.
    private func existingGoalsBlock() async -> String {
        guard let otherModel else { return "" }
        let existing = await otherModel.existingStatements()
        guard !existing.isEmpty else { return "" }
        return """

        Metas que YA existen (NO las repitas ni reformuladas; si el dueño vuelve a hablar de una, no la devuelvas):
        \(existing.map { "- \($0)" }.joined(separator: "\n"))

        """
    }

    // MARK: - Housekeeping final

    private func finish(cycle: Int) throws {
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            try db.execute(sql: "UPDATE consolidation_inbox SET consolidated_at=? WHERE cycle=? AND consolidated_at IS NULL",
                           arguments: [now, cycle])
            try db.execute(sql: "UPDATE consolidation_cycle SET stage='done', updated_at=?, completed_at=? WHERE cycle=?",
                           arguments: [now, now, cycle])
            try setMeta(db, "last_cycle_at", String(now))
            let previous = (try String.fetchOne(db, sql: "SELECT value FROM consolidation_meta WHERE key='successful_cycles'"))
                .flatMap(Int.init) ?? 0
            try setMeta(db, "successful_cycles", String(previous + 1))
        }
    }

    // MARK: - Estado del ciclo (checkpoints)

    private func currentCycle() throws -> (cycle: Int, stage: Stage) {
        try queue.write { db in
            if let row = try Row.fetchOne(db, sql: """
                SELECT cycle, stage FROM consolidation_cycle
                WHERE completed_at IS NULL ORDER BY cycle DESC LIMIT 1
                """) {
                let cycle: Int = row["cycle"]
                let stage = Stage(rawValue: row["stage"]) ?? .pending
                return (cycle, stage)
            }
            let maxCycle = try Int.fetchOne(db, sql: "SELECT MAX(cycle) FROM consolidation_cycle") ?? 0
            let next = maxCycle + 1
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO consolidation_cycle (cycle, stage, started_at, updated_at, completed_at)
                VALUES (?,?,?,?,NULL)
                """, arguments: [next, Stage.pending.rawValue, now, now])
            return (next, .pending)
        }
    }

    private func setStage(cycle: Int, stage: Stage) throws {
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            try db.execute(sql: "UPDATE consolidation_cycle SET stage=?, updated_at=? WHERE cycle=?",
                           arguments: [stage.rawValue, now, cycle])
        }
    }

    private func markDecided(cycle: Int, idx: Int, decision: String) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE cycle_distilled SET decided=1, decision=? WHERE cycle=? AND idx=?",
                           arguments: [decision, cycle, idx])
        }
    }

    // MARK: - Metadatos públicos

    public func lastCycleAt() -> Date? {
        let value = try? queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM consolidation_meta WHERE key='last_cycle_at'")
        }
        return (value.flatMap { $0 }).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }

    public func successfulCycles() -> Int {
        let value = try? queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM consolidation_meta WHERE key='successful_cycles'")
        }
        return (value.flatMap { $0 }).flatMap(Int.init) ?? 0
    }

    // MARK: - Report

    private func addedMemories(cycle: Int) throws -> [MemoryRecord] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM memory WHERE consolidation_cycle=? ORDER BY created_at ASC",
                             arguments: [cycle]).map(MemoryRecord.init(row:))
        }
    }

    private func decisionCounts(cycle: Int) throws -> [String: Int] {
        try queue.read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT decision, COUNT(*) AS n FROM cycle_distilled
                WHERE cycle=? AND decision IS NOT NULL GROUP BY decision
                """, arguments: [cycle]) {
                let decision: String = row["decision"]
                counts[decision] = row["n"]
            }
            return counts
        }
    }

    private func report(cycle: Int, completed: Bool) throws -> CycleReport {
        let counts = try decisionCounts(cycle: cycle)
        let distilledCount = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cycle_distilled WHERE cycle=?", arguments: [cycle]) ?? 0
        }
        let reconsolidated = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory WHERE consolidation_cycle=? AND revises_id IS NOT NULL",
                             arguments: [cycle]) ?? 0
        }
        let logged = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT report_json FROM cycle_log WHERE cycle=?", arguments: [cycle])
        }.flatMap { Self.decode(ReflectionDTO.self, from: $0) }
        let summary = logged?.summary ?? ""
        // Antes del reflection el cycle_log aún no existe: cuenta lo de cycle_distilled.
        let rejected = try logged?.rejected?.count ?? rejectedDistilled(cycle: cycle).count
        return CycleReport(
            cycle: cycle,
            distilled: distilledCount,
            added: counts["ADD"] ?? 0,
            updated: counts["UPDATE"] ?? 0,
            invalidated: counts["INVALIDATE"] ?? 0,
            noop: counts["NOOP"] ?? 0,
            reconsolidated: reconsolidated,
            reflectionSummary: summary,
            completed: completed,
            rejected: rejected)
    }

    static let rejectedPrefix = "REJECTED: "

    private func rejectedDistilled(cycle: Int) throws -> [RejectedDTO] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT candidate_json, decision FROM cycle_distilled
                WHERE cycle=? AND decision LIKE 'REJECTED:%' ORDER BY idx ASC
                """, arguments: [cycle]).compactMap { row in
                let json: String = row["candidate_json"]
                let decision: String = row["decision"]
                guard let data = json.data(using: .utf8),
                      let candidate = try? JSONDecoder().decode(MemoryCandidate.self, from: data) else { return nil }
                return RejectedDTO(content: candidate.content,
                                   reason: String(decision.dropFirst(Self.rejectedPrefix.count)))
            }
        }
    }

    private func persistReflection(cycle: Int, summary: String, insights: [String],
                                   extraRejected: [RejectedDTO] = []) throws {
        let rejected = try rejectedDistilled(cycle: cycle) + extraRejected
        let dto = ReflectionDTO(summary: summary, insights: insights, self_proposals: nil, inferred_goals: nil,
                                rejected: rejected.isEmpty ? nil : rejected)
        let json = String(data: (try? JSONEncoder().encode(dto)) ?? Data(), encoding: .utf8) ?? "{}"
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO cycle_log (cycle, report_json, ts) VALUES (?,?,?)",
                           arguments: [cycle, json, now])
        }
    }

    private func setMeta(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO consolidation_meta (key, value) VALUES (?,?)",
                       arguments: [key, value])
    }

    // MARK: - Provider (Haiku, single-shot)

    private func complete(_ turnClass: TurnClass, system: String, user: String, maxOutputTokens: Int) async throws -> String {
        guard let binding = selector.binding(for: turnClass) else {
            throw ClassifiedError.fatal(status: -1, message: "Sin córtex configurado para Consolidator.")
        }
        var route = binding.router.route(turnClass)
        // El ciclo va SIEMPRE por Haiku sin effort (§4.7): si la config no define
        // la clase y cae a Opus, respetamos el modelo pero el maxTokens del ciclo.
        route = ModelRoute(model: route.model, effort: ModelParamPolicy.policy(for: route.model).allowsEffort ? route.effort : nil,
                           maxTokens: min(route.maxTokens, maxOutputTokens))
        let opts = binding.callOpts(route: route, systemPromptBase: system)
        let response = try await binding.provider.completeCollecting(AssembledContext(messages: [.user(user)]), tools: [], opts: opts)
        if let telemetry {
            try? telemetry.record(sessionId: "consolidator", turnClass: turnClass, model: route.model,
                                  usage: response.usage, toolCalls: 0, retries: 0)
        }
        return response.content.compactMap { block in
            if case .text(let t) = block { return t } else { return nil }
        }.joined()
    }

    // MARK: - Parseo tolerante de JSON

    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        for candidate in jsonCandidates(text) {
            if let data = candidate.data(using: .utf8),
               let value = try? JSONDecoder().decode(T.self, from: data) {
                return value
            }
        }
        return nil
    }

    /// Extrae posibles bloques JSON del texto (crudo, o el primer arreglo/objeto
    /// balanceado). Los modelos suelen envolver el JSON en prosa o ```json.
    static func jsonCandidates(_ text: String) -> [String] {
        var out: [String] = [text]
        for opener: Character in ["[", "{"] {
            let closer: Character = opener == "[" ? "]" : "}"
            guard let start = text.firstIndex(of: opener) else { continue }
            var depth = 0
            var idx = start
            while idx < text.endIndex {
                let ch = text[idx]
                if ch == opener { depth += 1 }
                else if ch == closer {
                    depth -= 1
                    if depth == 0 {
                        out.append(String(text[start...idx]))
                        break
                    }
                }
                idx = text.index(after: idx)
            }
        }
        return out
    }
}

// MARK: - DTOs de las respuestas de Haiku

private struct DistilledFact: Decodable {
    let content: String
    let kind: String?
    let importance: Int?
    let event_at: String?

    func candidate(source: String) -> MemoryCandidate {
        MemoryCandidate(content: content,
                        kind: kind.flatMap { MemoryKind(rawValue: $0) } ?? .semantic,
                        importance: importance ?? 5,
                        eventAt: nil,
                        source: source)
    }
}

private struct DecisionDTO: Decodable {
    let decision: String
    let target_id: String?
    let reason: String?
}

private struct RevisionDTO: Decodable {
    let action: String?     // keep | revise | invalidate
    let content: String?
    let importance: Int?
    let reason: String?
}

private struct ReflectionDTO: Codable {
    let summary: String
    let insights: [String]?
    let self_proposals: [SelfProposalDTO]?
    let inferred_goals: [InferredGoalDTO]?
    var rejected: [RejectedDTO]? = nil
}

/// Rechazo auditable del DistillGuard (va al cycle_log, jamás al Brain).
private struct RejectedDTO: Codable {
    let content: String
    let reason: String
}

private struct SelfProposalDTO: Codable {
    let field: String       // identity | values | capabilities | style | historySummary
    let value: String
    let rationale: String?
}

/// Predicado observable emitido por Haiku (§5.8) o por la tool `goals`. Lenient:
/// un `kind` desconocido o parámetros faltantes ⇒ toPredicate() nil, sin romper el parseo.
struct PredicateDTO: Codable {
    let kind: String
    let value: Int?
    let hours: Double?
    let last_days: Int?
    let min_minutes: Int?
    let within_days: Int?
    let topic: String?
    let days: Int?
    let every_days: Int?

    func toPredicate() -> ObservablePredicate? {
        switch kind {
        case "workouts_per_week": return value.map { .workoutsPerWeek(atLeast: $0) }
        case "reminders_overdue_at_most": return value.map { .remindersOverdue(atMost: $0) }
        case "sleep_hours_at_least": return hours.map { .sleepHours(atLeast: $0, lastDays: last_days ?? 7) }
        case "calendar_has_free_slot": return min_minutes.map { .calendarFreeSlot(minMinutes: $0, withinDays: within_days ?? 7) }
        case "days_since_last_mention_at_most": return topic.map { .daysSinceLastMention(topic: $0, atMost: days ?? 7) }
        case "progress_check_in": return .progressCheckIn(everyDays: max(1, every_days ?? 7))
        default: return nil
        }
    }
}

private struct StatedGoalDTO: Codable {
    let statement: String
    let evidence: String?
    let priority: Int?
    let predicate: PredicateDTO?
}

private struct InferredGoalDTO: Codable {
    let statement: String
    let rationale: String?
    let priority: Int?
    let predicate: PredicateDTO?
}

// MARK: - Prompts (salida JSON estricta)

extension Consolidator {
    /// El prompt del ciclo es harness (código), no Remote Config: solo el system
    /// base vive en RC. v2 (campo batch 3): criterios explícitos + negativos reales.
    static let distillPrompt = """
    Eres el proceso de consolidación de memoria de largo plazo de un asistente personal. Recibes mensajes que el DUEÑO le escribió al asistente. Tu trabajo: extraer SOLO hechos DURABLES que sigan siendo ciertos y útiles dentro de semanas.

    SÍ extrae (en tercera persona, sobre el dueño — "El dueño…"):
    - hechos sobre el dueño: dónde vive, a qué se dedica, su salud, sus rutinas;
    - su gente: nombres y relación ("La hermana del dueño se llama Ana");
    - su mundo: lugares, proyectos, empresas, mascotas, objetos que le importan;
    - sus preferencias y gustos estables ("El dueño prefiere reuniones en la mañana");
    - eventos con fecha ("El dueño viaja a Lima el 12 de noviembre");
    - cómo el dueño se relaciona con el asistente cuando es un hecho del dueño ("El dueño llama Betty a su asistente").

    PROHIBIDO (devuelve nada por ellos):
    - las PREGUNTAS o pedidos del dueño, ni reformuladas: "¿Qué tengo pendiente en mi agenda?", "Que modelo usas para responder?", "Betty cuéntame sobre cómo funcionas" → NADA;
    - descripciones del asistente, sus capacidades, su modelo o su funcionamiento: "El asistente utiliza un modelo de lenguaje para procesar…" → NADA;
    - trivia de la conversación misma ("El dueño preguntó por su agenda", "El dueño saludó") → NADA;
    - saludos, agradecimientos, charla trivial, estados de ánimo pasajeros;
    - copiar literal el texto del mensaje.

    Si los mensajes no dejan ningún hecho durable, devuelve [] — eso es un resultado CORRECTO, no un fallo. Prefiere 0 memorias a 1 memoria basura.

    Devuelve SOLO un arreglo JSON:
    [{"content":"hecho atómico en tercera persona","kind":"semantic|episodic|procedural","importance":1-10,"event_at":null}]
    """

    static let decisionPrompt = """
    Decide qué hacer con un candidato de memoria frente a memorias existentes similares. Devuelve SOLO un objeto JSON:
    {"decision":"ADD|UPDATE|INVALIDATE|NOOP","target_id":"id o null","reason":"por qué"}
    ADD si es información nueva; UPDATE si refina/reemplaza una existente (target_id la vieja); INVALIDATE si el candidato indica que una existente ya no es cierta (target_id la vieja); NOOP si duplica una existente.
    """

    static let reconsolidationPrompt = """
    Reevalúa una memoria a la luz de que fue recuperada con frecuencia o contradicha. Devuelve SOLO un objeto JSON:
    {"action":"keep|revise|invalidate","content":"contenido corregido si revise","importance":1-10,"reason":"por qué"}
    """

    static let reflectionPrompt = """
    Resume el ciclo de consolidación. Los insights son conclusiones de alto nivel sobre el DUEÑO y su mundo (jamás sobre el asistente, su modelo o sus capacidades, ni sobre la conversación misma, ni preguntas). Sin insights durables, insights=[]. Devuelve SOLO un objeto JSON:
    {"summary":"una frase de qué aprendiste sobre el dueño","insights":["insight de alto nivel", "..."],"self_proposals":[{"field":"capabilities|style|historySummary|identity|values","value":"nuevo valor propuesto (para listas: items separados por saltos de línea)","rationale":"por qué"}],"inferred_goals":[{"statement":"meta inferida del dueño","rationale":"por qué","priority":1-10,"predicate":{"kind":"...","value":N}}]}
    Usa self_proposals SOLO si el ciclo aporta evidencia real para ajustar la identidad del asistente. Usa inferred_goals SOLO si infieres una meta que el dueño NO declaró explícitamente (requerirá su confirmación) y que NO está en la lista de metas que ya existen, ni reformulada ("Perder 10 kg en un plazo" = "Bajar 10 kg"). statement corto en infinitivo o segunda persona ("Bajar 10 kg"), NUNCA "El dueño quiere…". Si no aplica, omite el campo o déjalo vacío.
    Predicados observables válidos (kind): workouts_per_week{value}, reminders_overdue_at_most{value}, sleep_hours_at_least{hours,last_days}, calendar_has_free_slot{min_minutes,within_days}, days_since_last_mention_at_most{topic,days}, progress_check_in{every_days} (el dueño reporta avance cada N días; úsalo para metas de hábito o ahorro sin otro observable).
    """

    static let goalsPrompt = """
    Eres el proceso que extrae METAS DECLARADAS por el dueño ("quiero X", "mi meta es Y", "necesito Z de forma recurrente"). Ignora deseos triviales o de un solo uso. Para cada meta estable devuelve statement (la meta corta en infinitivo, como la diría el dueño: "Bajar 10 kg", "Entrenar 3 veces por semana"; NUNCA "El dueño quiere…"), evidence (cita textual del mensaje), priority (1-10) y un predicate observable de la lista cerrada. Devuelve SOLO un arreglo JSON:
    [{"statement":"...","evidence":"cita","priority":1-10,"predicate":{"kind":"...","value":N}}]
    Predicados válidos (kind): workouts_per_week{value}, reminders_overdue_at_most{value}, sleep_hours_at_least{hours,last_days}, calendar_has_free_slot{min_minutes,within_days}, days_since_last_mention_at_most{topic,days}, progress_check_in{every_days} (el dueño reporta avance cada N días; úsalo para metas de hábito o ahorro sin otro observable).
    No devuelvas metas que ya existen, ni reformuladas ("Bajar 10 kg de peso" = "Bajar 10 kg"): una meta, una sola vez.
    Si no hay metas declaradas nuevas, devuelve [].
    """
}
