import Foundation

/// Reads the WHOLE KistRunner family (KistRunner.swift + KistRunner+*.swift) as one string. Source-projection
/// tests pin wiring by grepping KistRunner's source; the run() decomposition moved helper methods (research,
/// council, fleet, plan-execute, provider selection, sticky-bar self-test) into KistRunner+*.swift extension
/// files, so those pins must read the family, not just the core file.
func kistRunnerFamilySource(_ testFile: StaticString = #filePath) -> String {
    var dir = URL(fileURLWithPath: "\(testFile)").deletingLastPathComponent()
    for _ in 0..<10 {
        let src = dir.appendingPathComponent("Sources/Kist")
        if FileManager.default.fileExists(atPath: src.appendingPathComponent("KistRunner.swift").path) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? []
            return files
                .filter { $0 == "KistRunner.swift" || $0.hasPrefix("KistRunner+") }
                .sorted()
                .compactMap { try? String(contentsOf: src.appendingPathComponent($0), encoding: .utf8) }
                .joined(separator: "\n")
        }
        dir.deleteLastPathComponent()
    }
    return ""
}
