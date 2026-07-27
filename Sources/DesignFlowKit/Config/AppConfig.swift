import Foundation

/// Fail-fast configuration. Real keys come from env or an untracked config.json —
/// never from source. `dryRun` is the only mode allowed to run without a key.
public struct AppConfig: Sendable {
    public var openAIKey: String?
    public var model: String
    public var outputRoot: URL
    public var loopIntervalSeconds: UInt64
    public var dryRun: Bool

    public init(
        openAIKey: String?,
        model: String,
        outputRoot: URL,
        loopIntervalSeconds: UInt64,
        dryRun: Bool
    ) {
        self.openAIKey = openAIKey
        self.model = model
        self.outputRoot = outputRoot
        self.loopIntervalSeconds = loopIntervalSeconds
        self.dryRun = dryRun
    }

    public enum ConfigError: Error, CustomStringConvertible {
        case missingKey
        public var description: String {
            switch self {
            case .missingKey:
                return "No OpenAI key found. Set OPENAI_API_KEY, add it to config.json, or run with --dry-run."
            }
        }
    }

    /// Load from environment first, then config.json in `cwd`. Sentinel placeholder
    /// values are treated as absent so a template file can't masquerade as a key.
    public static func load(
        cwd: URL,
        dryRun: Bool,
        intervalOverride: UInt64? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppConfig {
        let fileValues = readConfigFile(at: cwd.appendingPathComponent("config.json"))

        let key = sanitize(env["OPENAI_API_KEY"]) ?? sanitize(fileValues["openai_api_key"])
        let model = sanitize(env["DESIGNFLOW_MODEL"]) ?? sanitize(fileValues["model"]) ?? "gpt-4o"
        let outputRoot: URL = {
            if let raw = sanitize(env["DESIGNFLOW_OUTPUT"]) {
                return URL(fileURLWithPath: raw, isDirectory: true)
            }
            return cwd.appendingPathComponent("workspaces", isDirectory: true)
        }()
        let interval = intervalOverride
            ?? UInt64(sanitize(env["DESIGNFLOW_INTERVAL"]) ?? "") ?? 300

        if !dryRun && key == nil { throw ConfigError.missingKey }

        return AppConfig(
            openAIKey: key,
            model: model,
            outputRoot: outputRoot,
            loopIntervalSeconds: interval,
            dryRun: dryRun
        )
    }

    private static func sanitize(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        let placeholders = ["YOUR_OPENAI_API_KEY_HERE", "YOUR_API_KEY_HERE", "changeme"]
        if placeholders.contains(where: { v.caseInsensitiveCompare($0) == .orderedSame }) { return nil }
        return v
    }

    private static func readConfigFile(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj where v is String { out[k] = v as? String }
        return out
    }
}
