// SkillStep.swift — un paso del front-matter `steps:` de un skill, leído como
// llamada de tool: `tool.operación(arg=valor, …)`. La clasificación
// aferente/eferente del SkillEngine y el SkillRunner parten de aquí.

import Foundation

public enum SkillStep {
    /// "calendar.list(days_ahead=7)" → "calendar.list"; nil si no tiene la forma
    /// `tool.operación` (un paso en prosa no es ejecutable ⇒ eferente, fail-closed).
    static func operationKey(_ step: String) -> String? {
        let trimmed = step.trimmingCharacters(in: .whitespaces)
        let head = trimmed.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
        let parts = head.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } })
        else { return nil }
        return head
    }
}
