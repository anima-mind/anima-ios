// QuoteRx.swift — las regex de las heurísticas de "responder citando" (#43)
// en el modelo local, como `ICURegex` precompiladas (ver ICURegex.swift: la
// `Regex` de Swift dejaba sin hilos al pool cooperativo en el CI de 3
// núcleos). En archivo propio para no chocar con el enum Rx de LocalToolAdapter.
// Cada uso va detrás de un corte barato.

import Foundation

extension Rx {
    static let weekdayNames = ["domingo", "lunes", "martes", "miercoles", "jueves", "viernes", "sabado"]

    /// Corte barato: ¿nombra un día de la semana y un número?
    static func mayNameWeekdayAndNumber(_ text: String) -> Bool {
        text.contains(where: \.isNumber) && weekdayNames.contains(where: text.contains)
    }

    // "<día de la semana> <N>" y lo que viene detrás.
    static let weekdayWithNumber = ICURegex(#"\b(domingo|lunes|martes|miercoles|jueves|viernes|sabado) (\d{1,2})\b(.*)$"#)
    static let weekdayCommaNumber = ICURegex(#"\b(domingo|lunes|martes|miercoles|jueves|viernes|sabado),? (\d{1,2})\b"#)
    static let weekdayExplicitDate = ICURegex(#"\b(domingo|lunes|martes|miercoles|jueves|viernes|sabado),? (?:\d{1,2}) de [a-z]+"#)
    /// Detrás del número, siempre hora: "8:30", "3 pm", "8 y 30", "7 horas"…
    static let alwaysHourTail = ICURegex(#"^\s*(?::|\.\d|h\b|hrs?\b|horas?\b|minutos?\b|mins?\b|dias?\b|semanas?\b|am\b|pm\b|a\.?\s?m\b|p\.?\s?m\b|de la$|y media\b|y cuarto\b|y \d{1,2}\b|menos\b)"#)
    /// Detrás del número, una franja ("en la tarde").
    static let bandTail = ICURegex(#"^\s*(?:de|en|por|a) la (?:manana|tarde|noche|madrugada)\b"#)
    /// Una franja en el texto del dueño.
    static let dayBand = ICURegex(#"\b(?:en|por|de|a) la (?:tarde|noche|madrugada)\b|\b(?:en|por) la manana\b|\bal mediodia\b"#)

    // Pedidos sobre el recordatorio citado.
    static let doneAlone = ICURegex(#"^(?:ok |okay |bueno |si )?(?:listo|hecho|cumplido|completado|ya quedo|ya esta hecho|esta hecho)$"#)
    static let giveAsDone = ICURegex(#"^(?:listo |ok )?(?:dale|dalo|dala|marcalo|marcala) (?:por|como) hech[oa]$"#)
    static let completedPast = ICURegex(
        "^(?:listo |ok |bueno |si )?(?:ya )?(?:lo |la |le |los |las )?(?:" + LocalToolAdapter.completedVerbs
            + ")(?: (?:el|la|los|las|mi|mis|su|sus|un|una)(?: \\w+){1,3})?$")
    static let undoDone = ICURegex(#"\b(?:deshaz(?:lo|la)?|deshacer(?:lo|la)?|desmarca(?:lo|la)?|reactiva(?:lo|la)?|no lo he hecho|no la he hecho|no lo hice|no la hice|(?:todavia|aun) no lo (?:hice|he hecho|hago)|me equivoque|no estaba hecho|no esta hecho)\b"#)
    static let undoCues = ["desh", "desm", "reactiv", "no l", "equivoq", "no esta", "no estaba"]
}
