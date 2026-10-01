import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Evaluated artifacts, not a popularity-based trust list. New discoveries go through
/// the existing scout/vet/onboard path before being added to automatic acquisition.
public struct ManagedLocalModel: Sendable, Equatable {
    public let model: String
    public let huggingFaceRepo: String
    public let manifestDigest: String
    public let minimumHostGB: UInt64
    public let maximumDownloadBytes: Int64

    public static let catalog: [ManagedLocalModel] = [
        .init(model: "qwen3.5:9b-q4_K_M", huggingFaceRepo: "Qwen/Qwen3.5-9B",
              manifestDigest: "6488c96fa5faab64bb65cbd30d4289e20e6130ef535a93ef9a49f42eda893ea7",
              minimumHostGB: 16, maximumDownloadBytes: 8 * 1_073_741_824),
        .init(model: "qwen3-vl:4b-instruct", huggingFaceRepo: "Qwen/Qwen3-VL-4B-Instruct",
              manifestDigest: "ee4b975b58c17ce268cd19d40db35d5edc64603035d2ffc1fee1968eb0947f7b",
              minimumHostGB: 8, maximumDownloadBytes: 4 * 1_073_741_824)
    ]

    public static func lookup(_ model: String) -> ManagedLocalModel? {
        catalog.first { $0.model == model }
    }

    /// A host-memory ceiling is only an admission check, not a claim about speed or quality.
    public func fits(memoryBytes: UInt64, memoryPressure: Int) -> Bool {
        // macOS warning pressure can include the already-resident model itself. Critical
        // pressure blocks another inference; a warning alone must not pin routing to cloud.
        memoryBytes >= minimumHostGB * 1_073_741_824 && memoryPressure < 4
    }

    public static func hostMemoryPressure() -> Int {
        #if canImport(Darwin)
        var level: Int32 = 0
        var length = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &length, nil, 0) == 0 {
            return Int(level)
        }
        #endif
        return 0 // unavailable; physical-memory admission still applies
    }

    static func validateMetadata(_ json: [String: Any], candidate: Self) -> Bool {
        guard json["id"] as? String == candidate.huggingFaceRepo,
              json["private"] as? Bool == false,
              json["gated"] as? Bool == false,
              json["disabled"] as? Bool != true,
              let sha = json["sha"] as? String, sha.count == 40,
              sha.allSatisfy({ $0.isHexDigit }),
              let card = json["cardData"] as? [String: Any],
              card["license"] as? String == "apache-2.0" else { return false }
        return true
    }

    static func isLoopback(_ endpoint: URL) -> Bool {
        endpoint.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(endpoint.host ?? "")
            && endpoint.user == nil && endpoint.password == nil
            && endpoint.query == nil && endpoint.fragment == nil && endpoint.path == "/api/chat"
    }
}

/// Bounds cumulative advertised layer sizes, including progress messages for different layers.
/// A status line can never authorize another model, command or executable download.
struct LocalModelPullProgress {
    let maximumBytes: Int64
    private var layers: [String: Int64] = [:]
    private(set) var complete = false

    init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }

    mutating func consume(_ data: Data) throws {
        guard data.count <= 65_536,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error"] == nil else { throw failure("invalid model download response") }
        if let total = json["total"] as? Int64 {
            guard total >= 0, total <= maximumBytes, let digest = json["digest"] as? String,
                  digest.hasPrefix("sha256:"), digest.count == 71,
                  digest.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
                throw failure("model download exceeded its approved size or has no layer identity")
            }
            layers[digest] = max(layers[digest] ?? 0, total)
            guard layers.count <= 32, layers.values.reduce(0, +) <= maximumBytes else {
                throw failure("model download exceeded its approved total size")
            }
        }
        if json["status"] as? String == "success" { complete = true }
    }

    private func failure(_ reason: String) -> AIProviderError {
        .transport("Local model unavailable: \(reason)")
    }
}
