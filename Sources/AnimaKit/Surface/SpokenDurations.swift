// SpokenDurations.swift — lo que dicen CarPlay y Siri: "90 min" se dice "una
// hora y media" y "715 minutos", "11 horas y 55 minutos" (DurationText.spoken).

import Foundation
import AnimaWidgetCore

enum SpokenDurations {
    static let minutes = ICURegex(#"\b(\d{1,5}) ?(?:minutos|minuto|mins|min)\b"#, caseInsensitive: true)

    static func apply(_ text: String) -> String {
        guard text.range(of: "min", options: .caseInsensitive) != nil else { return text }
        var out = ""
        var cursor = text.startIndex
        for match in minutes.matches(in: text) {
            guard let value = match[1].flatMap({ Int($0) }) else { continue }
            out += text[cursor..<match.range.lowerBound]
            out += DurationText.spoken(minutes: value)
            cursor = match.range.upperBound
        }
        out += text[cursor...]
        return out
    }
}
