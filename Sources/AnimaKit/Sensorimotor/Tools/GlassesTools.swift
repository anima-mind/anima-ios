// GlassesTools.swift — las tools del segundo cuerpo (doc 05 §5), declaradas
// SIEMPRE en el array `tools` (el prefijo cacheado no muta con el link): sin
// gafas, el guard de cuerpo responde `is_error: gafas no conectadas`
// (errorClass glasses_unavailable) sin pedir confirmación ni ejecutar.
//   glasses_show   — el agente proyecta una card al HUD. Aferente de render
//                    (no muta el mundo): allow, con rate limit (etiqueta §4.3).
//                    Valida el árbol contra el vocabulario CERRADO y rechaza
//                    lo inválido con el porqué.
//   glasses_camera — foto POV. Eferente → ask SIEMPRE (§8); la confirmación se
//                    renderiza EN LAS GAFAS y se acepta con pinch (el
//                    SurfaceConfirmationRouter la enruta). El JPEG baja por el
//                    pipeline de imagen existente (ImageDownscaler ≤1568px) y
//                    entra al contexto como image block adjunto al tool_result.

import Foundation

/// Lo que las tools necesitan del cuerpo-gafas (la GlassesHUDSurface lo cumple).
public protocol GlassesToolHost: Sendable {
    func glassesActive() async -> Bool
    /// Proyecta la card (ya validada). false ⇒ no se pudo mostrar.
    func project(_ card: HUDFlexBox) async -> Bool
    /// Captura la foto POV (bytes JPEG/HEIC del SDK).
    func capturePOV() async throws -> Data
}

public enum GlassesToolText {
    public static let unavailable = "Gafas no conectadas: no puedo usarlas ahora. Responde por el teléfono."
}

public struct GlassesShowTool: SensorimotorTool {
    public static let name = "glasses_show"
    private let host: (any GlassesToolHost)?
    private let limiter: ProjectionRateLimiter

    public init(host: (any GlassesToolHost)?, limiter: ProjectionRateLimiter = ProjectionRateLimiter()) {
        self.host = host
        self.limiter = limiter
    }

    public var spec: ToolSpec {
        .client(
            name: Self.name,
            description: """
                Proyecta UNA card corta en el HUD de las gafas del dueño (Meta Ray-Ban Display). \
                Úsala solo si las gafas están conectadas (lo dice la línea "Cuerpo:" del contexto) y \
                ver algo en la cara ayuda: una agenda de 3 ítems, un dato, una confirmación. \
                Vocabulario CERRADO — cualquier otra cosa se rechaza: nodos "flexbox" (direction \
                column|row, spacing, padding 0–64, background none|card, children), "text" (content, \
                style heading ≤40 car.|body ≤200|meta ≤60, color primary|secondary), "icon" (name del \
                catálogo del SDK: calendar, bell, checkmarkCircle, clock, speechBubble, phone, eye, \
                exclamationTriangle, smartGlasses…; no existe mic), "image" (uri https), "button" \
                (label, style primary|secondary|outline, icon, action dismiss|on_phone|talk, \
                primary_action true en MÁXIMO uno = recibe el foco) y \
                "button_group" (alignment, buttons). Máximo 2 botones propios (el HUD agrega "Atrás"). \
                Lo largo va al teléfono, no al HUD.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "tree": .object([
                        "type": .string("object"),
                        "description": .string("Root flexbox de la card (ver descripción)."),
                    ]),
                ]),
                "required": .array([.string("tree")]),
                "additionalProperties": .bool(false),
            ]))
    }

    public func kind(for input: JSONValue) -> ToolKind { .afferent }
    public func operation(for input: JSONValue) -> String { "project_card" }

    public func bodyGuard(for input: JSONValue) async -> ToolResult? {
        guard let host, await host.glassesActive() else {
            return ToolResult(content: GlassesToolText.unavailable, isError: true)
        }
        return nil
    }

    public func execute(_ input: JSONValue) async -> ToolResult {
        guard let host else { return ToolResult(content: GlassesToolText.unavailable, isError: true) }
        guard let tree = input["tree"] else {
            return ToolResult(content: "Input inválido: falta 'tree'.", isError: true)
        }
        let box: HUDFlexBox
        do {
            box = try HUDTreeParser.parseRoot(tree)
            try HUDValidator.validate(HUDRenderer.render(.agentCard(box)))
        } catch {
            return ToolResult(content: "Árbol inválido para el HUD: \(error). Corrige y reintenta con el vocabulario cerrado.",
                              isError: true)
        }
        guard await limiter.allow() else {
            return ToolResult(content: "Límite de cards en las gafas alcanzado (\(limiter.limit)/hora): respóndelo por voz o en el teléfono.",
                              isError: true)
        }
        guard await host.project(box) else {
            return ToolResult(content: GlassesToolText.unavailable, isError: true)
        }
        return ToolResult(content: "Card proyectada en las gafas.")
    }
}

public struct GlassesCameraTool: SensorimotorTool {
    public static let name = "glasses_camera"
    private let host: (any GlassesToolHost)?

    public init(host: (any GlassesToolHost)?) {
        self.host = host
    }

    public var spec: ToolSpec {
        .client(
            name: Self.name,
            description: """
                Toma UNA foto con la cámara de las gafas del dueño (su punto de vista) para ver lo que \
                él está viendo ("¿qué estoy viendo?"). Requiere su confirmación con pinch EN las gafas: \
                nunca captura en silencio. La foto se adjunta (JPEG, lado largo ≤1568px) para que la \
                describas. Solo si las gafas están conectadas.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "reason": .object([
                        "type": .string("string"),
                        "description": .string("Para qué necesitas la foto (se le muestra al dueño en las gafas)."),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]))
    }

    // Perceptualmente aferente, pero la regla de captura (§8) la fuerza a `ask`.
    public func kind(for input: JSONValue) -> ToolKind { .efferent }
    public func operation(for input: JSONValue) -> String { "capture_pov" }
    public func confirmationSummary(for input: JSONValue) -> String {
        Self.reason(input)
    }

    static func reason(_ input: JSONValue) -> String {
        let reason = input["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? "Para ver lo que estás mirando." : reason
    }

    public func bodyGuard(for input: JSONValue) async -> ToolResult? {
        guard let host, await host.glassesActive() else {
            return ToolResult(content: GlassesToolText.unavailable, isError: true)
        }
        return nil
    }

    public func execute(_ input: JSONValue) async -> ToolResult {
        guard let host else { return ToolResult(content: GlassesToolText.unavailable, isError: true) }
        let data: Data
        do {
            data = try await host.capturePOV()
        } catch {
            return ToolResult(content: "No se pudo tomar la foto con las gafas: \(error).", isError: true)
        }
        guard let output = ImageDownscaler.process(data) else {
            return ToolResult(content: "La foto de las gafas no pudo procesarse.", isError: true)
        }
        return ToolResult(
            content: "Foto POV de las gafas adjunta (\(output.pixelWidth)×\(output.pixelHeight)). Descríbela breve.",
            attachments: [.image(mediaType: output.mediaType, base64: output.base64)])
    }
}

/// Rate limit de proyección (doc 05 §4.3): ≤N cards por hora — jamás spamear la cara.
public actor ProjectionRateLimiter {
    public nonisolated let limit: Int
    private let window: TimeInterval
    private let now: @Sendable () -> Date
    private var stamps: [Date] = []

    public init(limit: Int = 12, window: TimeInterval = 3600, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = limit
        self.window = window
        self.now = now
    }

    public func allow() -> Bool {
        let t = now()
        stamps.removeAll { t.timeIntervalSince($0) >= window }
        guard stamps.count < limit else { return false }
        stamps.append(t)
        return true
    }
}

/// Enruta el `ask`: `glasses_camera` se confirma EN LAS GAFAS (card + pinch,
/// consentimiento en el mismo dispositivo, §8); todo lo demás, el sheet del
/// teléfono. Fail-closed: sin confirmador de gafas, la cámara se niega.
public struct SurfaceConfirmationRouter: ConfirmationProvider {
    public typealias GlassesConfirm = @Sendable (ConfirmationRequest) async -> Bool
    private let phone: ConfirmationProvider
    private let glasses: GlassesConfirm?

    public init(phone: ConfirmationProvider, glasses: GlassesConfirm?) {
        self.phone = phone
        self.glasses = glasses
    }

    public func confirm(_ request: ConfirmationRequest) async -> Bool {
        if request.tool == GlassesCameraTool.name {
            guard let glasses else { return false }
            return await glasses(request)
        }
        return await phone.confirm(request)
    }
}

/// Rompe el ciclo de cableado (las tools van al AgentLoop, y la superficie que
/// las atiende necesita el loop): las tools se declaran con este proxy y la
/// superficie se enchufa después. Sin superficie = sin gafas (fail-closed).
public final class LateBoundGlassesHost: GlassesToolHost, @unchecked Sendable {
    private let lock = NSLock()
    private var host: (any GlassesToolHost)?
    private var confirmer: (@Sendable (ConfirmationRequest) async -> Bool)?

    public init() {}

    public func bind(_ host: (any GlassesToolHost)?, confirm: (@Sendable (ConfirmationRequest) async -> Bool)?) {
        lock.lock(); self.host = host; self.confirmer = confirm; lock.unlock()
    }

    private var current: (any GlassesToolHost)? { lock.lock(); defer { lock.unlock() }; return host }

    public func glassesActive() async -> Bool { await current?.glassesActive() ?? false }
    public func project(_ card: HUDFlexBox) async -> Bool { await current?.project(card) ?? false }
    public func capturePOV() async throws -> Data {
        guard let current else { throw GlassesBodyError.unavailable("gafas no conectadas") }
        return try await current.capturePOV()
    }

    /// La confirmación pinch de la cámara (para SurfaceConfirmationRouter).
    public func confirm(_ request: ConfirmationRequest) async -> Bool {
        return await currentConfirmer?(request) ?? false
    }

    private var currentConfirmer: (@Sendable (ConfirmationRequest) async -> Bool)? {
        lock.lock(); defer { lock.unlock() }; return confirmer
    }
}
