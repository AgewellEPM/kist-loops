import Foundation

/// Reads the WHOLE KistRunner family (KistRunner.swift + KistRunner+*.swift) as one string. Source-projection
/// tests pin wiring by grepping KistRunner's source; the run() decomposition moved helper methods (research,
/// council, fleet, plan-execute, provider selection, sticky-bar self-test) into KistRunner+*.swift extension
/// files, so those pins must read the family, not just the core file.
func kistRunnerFamilySource(_ testFile: StaticString = #filePath, entryPointFirst: Bool = false) -> String {
    var dir = URL(fileURLWithPath: "\(testFile)").deletingLastPathComponent()
    for _ in 0..<10 {
        let src = dir.appendingPathComponent("Sources/Kist")
        if FileManager.default.fileExists(atPath: src.appendingPathComponent("KistRunner.swift").path) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: src.path)) ?? []
            return files
                .filter { $0 == "KistRunner.swift" || $0.hasPrefix("KistRunner+") }
                // Startup-order checks need run() before extension helpers; other projection tests
                // retain their historical ordering and scope their own function slices.
                .sorted { left, right in
                    if entryPointFirst && left == "KistRunner.swift" { return right != left }
                    if entryPointFirst && right == "KistRunner.swift" { return false }
                    return left < right
                }
                .compactMap { try? String(contentsOf: src.appendingPathComponent($0), encoding: .utf8) }
                .joined(separator: "\n")
        }
        dir.deleteLastPathComponent()
    }
    return ""
}
