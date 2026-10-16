import Foundation
import Testing
@testable import AnimaKit

@Suite struct ICURegexTests {
    @Test func groupsRangesAndReplacements() throws {
        let rx = ICURegex(#"(\d{1,2}) de ([a-z]+)(?: de (\d{4}))?"#)
        let m = try #require(rx.firstMatch(in: "el 15 de octubre a las 9"))
        #expect(m[1] == "15" && m[2] == "octubre" && m[3] == nil && m[9] == nil)
        #expect(m.whole == "15 de octubre")
        #expect(rx.matches(in: "1 de enero y 2 de mayo de 2027").map { String($0.whole) } == ["1 de enero", "2 de mayo de 2027"])
        #expect(rx.contains("3 de marzo") && !rx.contains("marzo"))
        #expect(ICURegex(#"\$\d"#).replacing(in: "a $1 b", with: "$9") == "a $9 b")
        #expect(ICURegex(#"(\d)([a-z])"#).replacing(in: "10kg 5m", template: "$1 $2") == "10 kg 5 m")
        #expect(ICURegex("hola", caseInsensitive: true).contains("HOLA, mi meta"))
        let named = try #require(ICURegex(#"meta de (?<old>\w+)"#).firstMatch(in: "mi meta de correr"))
        #expect(named["old"] == "correr" && named["nada"] == nil)
        // Texto con tildes y emojis: los rangos siguen siendo índices válidos del String.
        let accented = try #require(ICURegex("mañana").firstMatch(in: "😀 pasado mañana"))
        #expect("😀 pasado mañana"[accented.range] == "mañana")
    }

    @Test func theCheckScriptExists() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../scripts/check-no-swift-regex.sh").standardizedFileURL
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
    }
}
