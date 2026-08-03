import Foundation

/// Reads the WHOLE KistREPL family (KistREPL.swift + KistREPL+*.swift) as one string. Source-projection
/// tests pin wiring by grepping KistREPL's source; the run() decomposition moved helper methods into
/// KistREPL+*.swift modules, so those pins must read the family, not just the core file.
func kistREPLFamilySource(_ testFile: StaticString = #filePath) -> String {
    var dir = URL(fileURLWithPath: "\(testFile)").deletingLastPathComponent()
    for _ in 0..<10 {
        let src = dir.appendingPathComponent("Sources/Kist")
        if FileManager.default.fileExists(atPath: src.appendingPathComponent("KistREPL.swift").path) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? []
            return files
                .filter { $0 == "KistREPL.swift" || $0.hasPrefix("KistREPL+") }
                .sorted()
                .compactMap { try? String(contentsOf: src.appendingPathComponent($0), encoding: .utf8) }
                .joined(separator: "\n")
        }
        dir.deleteLastPathComponent()
    }
    return ""
}
