// SkillWorkshop.swift — el taller conversacional de skills (campo batch 3, FIX A).
// Crear/editar una skill es una CONVERSACIÓN de propósito (patrón
// "Conversational field" del design system, el mismo del Birth), no un form.
// Los turnos van por el AgentLoop normal pero en una sesión EFÍMERA: store en
// memoria (jamás el SymbolicStore del hilo principal), sin inbox de
// consolidación, sin Brain, sin tools y sin SkillEngine. El córtex activo
// redacta el markdown dentro de <skill>…</skill>; la UI lo muestra como
// borrador vivo y "Guardar" lo escribe a Documents/skills.

import Foundation

public enum SkillWorkshopMode: Sendable, Equatable {
    case create
    /// Editar la skill existente: su nombre original y su markdown de hoy.
    case edit(name: String, markdown: String)

    public var originalName: String? {
        if case .edit(let name, _) = self { return name }
        return nil
    }
}

public struct SkillWorkshopSession: Sendable {
    public let loop: AgentLoop
    public let sessionId: SessionID

    /// Marca del system de tarea (la usa el provider guionado de UI tests).
    public static let marker = "[TALLER DE SKILL]"

    /// Sesión efímera sobre el córtex activo. `telemetry` es la real: el costo
    /// de estos turnos se cuenta como cualquier otro.
    public static func make(selector: ProviderSelector, telemetry: Telemetry, selfModel: SelfModel?,
                            mode: SkillWorkshopMode) throws -> SkillWorkshopSession {
        let store = SymbolicStore(queue: try AnimaDatabase.inMemory())
        let loop = AgentLoop(selector: selector, store: store, telemetry: telemetry,
                             clientTools: [], serverTools: [],
                             brain: nil, inbox: nil, selfModel: selfModel,
                             realRegister: nil, skillEngine: nil,
                             taskInstructions: instructions(for: mode))
        return SkillWorkshopSession(loop: loop, sessionId: try store.startSession())
    }

    public static func instructions(for mode: SkillWorkshopMode) -> String {
        var text = """
        \(marker) Estás ayudando al dueño a redactar UNA skill: conocimiento procedural (cómo hacer algo), en markdown, que consultarás cuando su pedido encaje. Esto NO es la conversación general: no ejecutes nada ni uses tools.
        Conversa breve y en español, UNA pregunta a la vez, según lo que falte, en este orden: 1) qué quiere que aprendas a hacer, 2) cuándo deberías usarla (con qué palabras te lo pediría), 3) los pasos o detalles. Después pregunta si falta algo o si cambias algo.
        Tras CADA respuesta del dueño devuelve el borrador COMPLETO actualizado dentro de <skill>…</skill> y, DESPUÉS del bloque, una sola frase con la siguiente pregunta. Formato exacto:
        <skill>
        ---
        name: nombre-en-minusculas-con-guiones
        description: una línea de qué hace
        when: palabras o frases con las que el dueño lo pediría, separadas por comas
        ---
        1. Paso concreto en imperativo.
        2. …
        </skill>
        Reglas: no inventes datos que el dueño no dio; si algo falta, déjalo fuera y pregúntalo. Si el dueño dice que está bien o listo, devuelve el borrador final y dile que puede tocar Guardar.
        """
        if case .edit(let name, let markdown) = mode {
            text += """

            Esta es la skill tal como está hoy. Edítala según lo que pida el dueño y conserva lo demás. No cambies `name: \(name)` salvo que él lo pida explícitamente (renombrarla reinicia su práctica).
            <skill>
            \(markdown.trimmingCharacters(in: .whitespacesAndNewlines))
            </skill>
            """
        }
        return text
    }
}
