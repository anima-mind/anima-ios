// SelfModel.swift — la identidad con plasticidad decreciente (§5.5). Actor:
// escritura SOLO vía apply()/approve() (protected path; ninguna tool del
// Sensorimotor toca la tabla self_model). El reflection del ciclo propone
// cambios; cada propuesta pasa por el gate de plasticidad (Plasticity.regime,
// invariante cross-runtime). Los cambios identitarios en adolescencia/madurez
// no se aplican directo: caen a PendingOtherApproval (fail-closed, timeout 7d).

import Foundation
import GRDB

/// El render vivo de la identidad (§5.5). Reemplaza a ProvisionalSelfView en el
/// mid-conversation system message (§4.5).
public struct SelfView: Sendable, Equatable, Codable {
    public var identity: String          // quién soy, para quién existo
    public var values: [String]          // reglas que me doy
    public var capabilities: [String]    // qué sé hacer (con evidencia)
    public var style: String             // cómo hablo
    public var historySummary: String    // mi historia destilada
    public var version: Int

    public init(identity: String, values: [String], capabilities: [String],
                style: String, historySummary: String, version: Int) {
        self.identity = identity
        self.values = values
        self.capabilities = capabilities
        self.style = style
        self.historySummary = historySummary
        self.version = version
    }
}

/// Semilla del onboarding "Birth" (pregunta abierta #8): seed mínimo + bootstrap
/// libre. Puede nacer casi vacío; aquí un seed continuo con la Fase 1.
public struct Birth: Sendable, Equatable {
    public var name: String
    public var tone: String
    public var language: String
    public var values: [String]

    public init(name: String, tone: String, language: String, values: [String] = []) {
        self.name = name
        self.tone = tone
        self.language = language
        self.values = values
    }

    public static let seed = Birth(name: "Anima", tone: "cercano, directo y honesto",
                                   language: "español (es-CO)")

    public var seedView: SelfView {
        SelfView(identity: "Eres \(name), un asistente personal que existe para tu dueño.",
                 values: values,
                 capabilities: [],
                 style: "Tono: \(tone). Idioma por defecto: \(language).",
                 historySummary: "",
                 version: 1)
    }
}

/// Origen de un cambio del self (historial append-only).
public enum ChangeOrigin: String, Sendable, Codable, Equatable {
    case reflection, owner, bootstrap
}

/// Propuesta de cambio a un campo del self (la emite el reflection del ciclo).
public struct SelfProposal: Sendable, Equatable, Codable {
    public enum Field: String, Sendable, Codable, Equatable, CaseIterable {
        case identity, values, capabilities, style, historySummary
        /// identity y values son identitarios: en adolescencia/madurez requieren
        /// aprobación del Otro. capabilities/style/historySummary son menores.
        public var isIdentityClass: Bool { self == .identity || self == .values }
    }
    public var field: Field
    public var value: String          // arrays (values/capabilities): items separados por "\n"
    public var rationale: String
    public var origin: ChangeOrigin

    public init(field: Field, value: String, rationale: String, origin: ChangeOrigin = .reflection) {
        self.field = field
        self.value = value
        self.rationale = rationale
        self.origin = origin
    }
}

public enum ApplyResult: Sendable, Equatable {
    case accepted
    case rejected(reason: String)
    case pendingOtherApproval(id: String)
    case noChange
}

/// Cambio efectivo del self (historial append-only).
public struct SelfChange: Sendable, Equatable, Identifiable, Codable {
    public var id: Int64
    public var field: SelfProposal.Field
    public var before: String
    public var after: String
    public var rationale: String
    public var origin: ChangeOrigin
    public var at: Date
}

/// Cambio identitario a la espera del Otro (§5.5). Timeout 7 días → Rejected.
public struct PendingApproval: Sendable, Equatable, Identifiable, Codable {
    public enum Status: String, Sendable, Codable, Equatable { case pending, approved, rejected }
    public var id: String
    public var field: SelfProposal.Field
    public var before: String
    public var after: String
    public var rationale: String
    public var origin: ChangeOrigin
    public var createdAt: Date
    public var expiresAt: Date
    public var status: Status
}

/// Canal proactivo hacia el dueño (UserNotifications en el app shell). Inyectable
/// para tests; el default es no-op.
public protocol ApprovalNotifier: Sendable {
    func notifyPendingApproval(_ approval: PendingApproval) async
}

public struct NoopApprovalNotifier: ApprovalNotifier {
    public init() {}
    public func notifyPendingApproval(_ approval: PendingApproval) async {}
}

public actor SelfModel {
    private let queue: DatabaseQueue
    private let notifier: ApprovalNotifier
    private let now: @Sendable () -> Date
    private let approvalTTL: TimeInterval

    /// Timeout edge del PendingOtherApproval (§5.5): 7 días fail-closed.
    public static let defaultApprovalTTL: TimeInterval = 7 * 24 * 3600

    public init(queue: DatabaseQueue,
                birth: Birth = .seed,
                notifier: ApprovalNotifier = NoopApprovalNotifier(),
                approvalTTL: TimeInterval = SelfModel.defaultApprovalTTL,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.queue = queue
        self.notifier = notifier
        self.approvalTTL = approvalTTL
        self.now = now
        try? Self.seedIfNeeded(queue: queue, birth: birth, now: now())
    }

    private static func seedIfNeeded(queue: DatabaseQueue, birth: Birth, now: Date) throws {
        try queue.write { db in
            let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM self_model WHERE id=1") ?? 0
            guard exists == 0 else { return }
            let json = String(data: try JSONEncoder().encode(birth.seedView), encoding: .utf8) ?? "{}"
            let ts = now.timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO self_model (id, view_json, cycles, born_at, updated_at)
                VALUES (1, ?, 0, ?, ?)
                """, arguments: [json, ts, ts])
            try db.execute(sql: """
                INSERT INTO self_change (field, before_value, after_value, rationale, origin, ts)
                VALUES ('identity','', ?, 'nacimiento (Birth)', 'bootstrap', ?)
                """, arguments: [birth.seedView.identity, ts])
        }
    }

    // MARK: - Lectura

    public func view() -> SelfView {
        (try? loadView()) ?? Birth.seed.seedView
    }

    public func cycles() -> Int {
        let value: Int?? = try? queue.read { db in
            try Int.fetchOne(db, sql: "SELECT cycles FROM self_model WHERE id=1")
        }
        return value.flatMap { $0 } ?? 0
    }

    public func plasticity() -> Double { Plasticity.value(cycles: cycles()) }
    public func regime() -> Plasticity.Regime { Plasticity.regime(cycles: cycles()) }

    /// Render vivo, corto (<400 tokens) y determinista dado el mismo estado (§5.5,
    /// §4.5). Va en CADA turno como mid-conversation system: no puede inflar el
    /// contexto. Secciones vacías se omiten.
    public func render() -> String {
        let v = view()
        let p = plasticity()
        var lines: [String] = []
        lines.append("[SELF] \(v.identity) (identidad v\(v.version), plasticidad \(String(format: "%.2f", p)))")
        if !v.values.isEmpty {
            lines.append("Valores: " + v.values.map { "• \($0)" }.joined(separator: " "))
        }
        if !v.capabilities.isEmpty {
            lines.append("Capacidades: " + v.capabilities.map { "• \($0)" }.joined(separator: " "))
        }
        if !v.style.isEmpty { lines.append("Estilo: \(v.style)") }
        if !v.historySummary.isEmpty { lines.append("Historia: \(v.historySummary)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Gate de plasticidad

    /// Aplica una propuesta a través del gate de plasticidad (§5.5). Bootstrap:
    /// todo directo. Adolescencia/madurez: identity/values → PendingOtherApproval;
    /// capabilities/style/historySummary directo.
    @discardableResult
    public func apply(_ proposal: SelfProposal) -> ApplyResult {
        guard var current = try? loadView() else { return .rejected(reason: "self no disponible") }
        let before = fieldValue(current, proposal.field)
        let after = proposal.value
        if before == after { return .noChange }

        let regime = Plasticity.regime(cycles: cycles())
        let needsApproval = proposal.field.isIdentityClass && regime != .bootstrap
        if needsApproval {
            let id = enqueueApproval(field: proposal.field, before: before, after: after,
                                     rationale: proposal.rationale, origin: proposal.origin)
            return .pendingOtherApproval(id: id)
        }
        setField(&current, proposal.field, to: after)
        persist(view: current, change: (proposal.field, before, after, proposal.rationale, proposal.origin))
        return .accepted
    }

    /// El reflection del ciclo propone varios cambios; cada uno pasa por el gate.
    @discardableResult
    public func reflect(_ proposals: [SelfProposal]) -> [ApplyResult] {
        proposals.map { apply($0) }
    }

    // MARK: - Aprobaciones del Otro

    public func pendingApprovals() -> [PendingApproval] {
        (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM self_pending_approval WHERE status='pending' ORDER BY created_at ASC")
                .map(Self.approval(from:))
        }) ?? []
    }

    public func allApprovals(limit: Int = 100) -> [PendingApproval] {
        (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM self_pending_approval ORDER BY created_at DESC LIMIT ?",
                             arguments: [limit]).map(Self.approval(from:))
        }) ?? []
    }

    /// El dueño aprueba: aplica el cambio (origin=owner) y cierra la aprobación.
    @discardableResult
    public func approve(id: String) -> ApplyResult {
        guard let approval = fetchApproval(id: id), approval.status == .pending else {
            return .rejected(reason: "aprobación no encontrada o ya resuelta")
        }
        guard var current = try? loadView() else { return .rejected(reason: "self no disponible") }
        setField(&current, approval.field, to: approval.after)
        persist(view: current, change: (approval.field, approval.before, approval.after, approval.rationale, .owner))
        resolveApproval(id: id, status: .approved)
        return .accepted
    }

    public func reject(id: String) {
        resolveApproval(id: id, status: .rejected)
    }

    /// Expira las pendientes vencidas → Rejected (fail-closed, §5.5). Se corre al
    /// abrir la app y en el ciclo. Devuelve cuántas expiraron.
    @discardableResult
    public func expireStale() -> Int {
        let ts = now().timeIntervalSince1970
        return (try? queue.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM self_pending_approval WHERE status='pending' AND expires_at <= ?",
                                          arguments: [ts])
            if !ids.isEmpty {
                try db.execute(sql: "UPDATE self_pending_approval SET status='rejected', resolved_at=? WHERE status='pending' AND expires_at <= ?",
                               arguments: [ts, ts])
            }
            return ids.count
        }) ?? 0
    }

    // MARK: - Madurez (n de ciclos vividos)

    /// El Consolidator lo llama al cerrar un ciclo exitoso: n += 1 (madura la
    /// plasticidad, §5.5). n = ciclos vividos, no wall-time.
    public func recordSuccessfulCycle() {
        try? queue.write { db in
            try db.execute(sql: "UPDATE self_model SET cycles = cycles + 1, updated_at=? WHERE id=1",
                           arguments: [now().timeIntervalSince1970])
        }
    }

    /// Fija n directamente (bootstrap del onboarding / tests que simulan madurez).
    public func setCycles(_ n: Int) {
        try? queue.write { db in
            try db.execute(sql: "UPDATE self_model SET cycles=?, updated_at=? WHERE id=1",
                           arguments: [max(0, n), now().timeIntervalSince1970])
        }
    }

    public func changeHistory(limit: Int = 200) -> [SelfChange] {
        (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM self_change ORDER BY id DESC LIMIT ?", arguments: [limit])
                .map(Self.change(from:))
        }) ?? []
    }

    // MARK: - Persistencia interna

    private func loadView() throws -> SelfView? {
        try queue.read { db in
            guard let json: String = try String.fetchOne(db, sql: "SELECT view_json FROM self_model WHERE id=1"),
                  let data = json.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(SelfView.self, from: data)
        }
    }

    private func persist(view: SelfView,
                         change: (field: SelfProposal.Field, before: String, after: String, rationale: String, origin: ChangeOrigin)) {
        var bumped = view
        bumped.version += 1
        let json = String(data: (try? JSONEncoder().encode(bumped)) ?? Data(), encoding: .utf8) ?? "{}"
        let ts = now().timeIntervalSince1970
        try? queue.write { db in
            try db.execute(sql: "UPDATE self_model SET view_json=?, updated_at=? WHERE id=1", arguments: [json, ts])
            try db.execute(sql: """
                INSERT INTO self_change (field, before_value, after_value, rationale, origin, ts)
                VALUES (?,?,?,?,?,?)
                """, arguments: [change.field.rawValue, change.before, change.after,
                                 change.rationale, change.origin.rawValue, ts])
        }
    }

    private func enqueueApproval(field: SelfProposal.Field, before: String, after: String,
                                 rationale: String, origin: ChangeOrigin) -> String {
        let id = UUID().uuidString
        let created = now()
        let expires = created.addingTimeInterval(approvalTTL)
        let approval = PendingApproval(id: id, field: field, before: before, after: after,
                                       rationale: rationale, origin: origin,
                                       createdAt: created, expiresAt: expires, status: .pending)
        try? queue.write { db in
            try db.execute(sql: """
                INSERT INTO self_pending_approval
                    (id, field, before_value, after_value, rationale, origin, created_at, expires_at, status, resolved_at)
                VALUES (?,?,?,?,?,?,?,?, 'pending', NULL)
                """, arguments: [id, field.rawValue, before, after, rationale, origin.rawValue,
                                 created.timeIntervalSince1970, expires.timeIntervalSince1970])
        }
        let notifier = self.notifier
        Task { await notifier.notifyPendingApproval(approval) }
        return id
    }

    private func fetchApproval(id: String) -> PendingApproval? {
        try? queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM self_pending_approval WHERE id=?", arguments: [id])
                .map(Self.approval(from:))
        } ?? nil
    }

    private func resolveApproval(id: String, status: PendingApproval.Status) {
        try? queue.write { db in
            try db.execute(sql: "UPDATE self_pending_approval SET status=?, resolved_at=? WHERE id=? AND status='pending'",
                           arguments: [status.rawValue, now().timeIntervalSince1970, id])
        }
    }

    // MARK: - Campos

    private func fieldValue(_ v: SelfView, _ field: SelfProposal.Field) -> String {
        switch field {
        case .identity: return v.identity
        case .style: return v.style
        case .historySummary: return v.historySummary
        case .values: return v.values.joined(separator: "\n")
        case .capabilities: return v.capabilities.joined(separator: "\n")
        }
    }

    private func setField(_ v: inout SelfView, _ field: SelfProposal.Field, to value: String) {
        switch field {
        case .identity: v.identity = value
        case .style: v.style = value
        case .historySummary: v.historySummary = value
        case .values: v.values = Self.splitList(value)
        case .capabilities: v.capabilities = Self.splitList(value)
        }
    }

    static func splitList(_ s: String) -> [String] {
        s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func approval(from row: Row) -> PendingApproval {
        PendingApproval(
            id: row["id"],
            field: SelfProposal.Field(rawValue: row["field"]) ?? .capabilities,
            before: row["before_value"] ?? "",
            after: row["after_value"] ?? "",
            rationale: row["rationale"] ?? "",
            origin: ChangeOrigin(rawValue: row["origin"]) ?? .reflection,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            expiresAt: Date(timeIntervalSince1970: row["expires_at"]),
            status: PendingApproval.Status(rawValue: row["status"]) ?? .pending)
    }

    static func change(from row: Row) -> SelfChange {
        SelfChange(
            id: row["id"],
            field: SelfProposal.Field(rawValue: row["field"]) ?? .capabilities,
            before: row["before_value"] ?? "",
            after: row["after_value"] ?? "",
            rationale: row["rationale"] ?? "",
            origin: ChangeOrigin(rawValue: row["origin"]) ?? .reflection,
            at: Date(timeIntervalSince1970: row["ts"]))
    }
}
