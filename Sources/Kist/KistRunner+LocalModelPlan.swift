import Foundation
import AgentCore

extension KistRunner {
    static func runLocalModelPlan(_ model: String) async -> Int32 {
        do {
            let report = try await OllamaProvider().memoryAdmission(model: model)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            return report.admitted ? 0 : 2
        } catch {
            err("Local model plan unavailable: \(error.localizedDescription). No inference started.")
            return 2
        }
    }
}
