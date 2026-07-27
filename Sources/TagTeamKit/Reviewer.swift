import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A reviewer in the tag team: given a diff, returns its raw review text. Pluggable —
/// DeepSeek and Codex today; add more by conforming. The panel runs them in parallel
/// and `ReviewClassifier` turns each verdict into a fix/ship decision.
public protocol Reviewer: Sendable {
    var name: String { get }
    func review(diff: String) async throws -> String
}

public enum ReviewerError: Error, CustomStringConvertible {
    case missingKey(String)
    case transport(String)
    case tool(String)
    public var description: String {
        switch self {
        case let .missingKey(k): return "reviewer needs \(k) in the environment"
        case let .transport(m): return "reviewer transport error: \(m)"
        case let .tool(m): return "reviewer tool error: \(m)"
        }
    }
}

public enum TagTeam {
    /// The shared adversarial brief every reviewer gets.
    public static let reviewPrompt = """
    You are a ruthless adversarial code reviewer. Hunt for REAL defects — correctness \
    bugs, security holes, fail-open trust gaps, concurrency issues, and honesty \
    violations (something labeled safe/verified that isn't). For each finding give \
    SEVERITY (BLOCKER/HIGH/MED/LOW), the file, the concrete exploit or failure, and the \
    fix. Skip nits. Be specific and skeptical. End with exactly one line: SHIP or NO-SHIP.
    """
}

/// DeepSeek reviewer (OpenAI-compatible API). Key from DEEPSEEK_API_KEY.
public struct DeepSeekReviewer: Reviewer {
    public let name = "deepseek"
    private let apiKey: String
    private let model: String

    public init(apiKey: String = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? "",
                model: String = "deepseek-chat") {
        self.apiKey = apiKey
        self.model = model
    }

    public func review(diff: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ReviewerError.missingKey("DEEPSEEK_API_KEY") }
        var req = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": TagTeam.reviewPrompt],
                ["role": "user", "content": "Review this diff:\n\n" + diff],
            ],
            "temperature": 0.2,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String
            else { throw ReviewerError.transport("unexpected DeepSeek response") }
            return content
        } catch let e as ReviewerError { throw e }
        catch { throw ReviewerError.transport(error.localizedDescription) }
    }
}

/// Codex reviewer — shells to the local `codex` CLI in non-interactive mode.
public struct CodexReviewer: Reviewer {
    public let name = "codex"
    public init() {}

    public func review(diff: String) async throws -> String {
        let prompt = TagTeam.reviewPrompt + "\n\nDIFF:\n" + diff
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["codex", "exec", "--skip-git-repo-check", prompt]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { throw ReviewerError.tool("could not launch codex: \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw ReviewerError.tool("codex exited \(p.terminationStatus)") }
        return out
    }
}

public enum ReviewerFactory {
    public static func make(_ name: String) -> Reviewer? {
        switch name.lowercased() {
        case "deepseek": return DeepSeekReviewer()
        case "codex": return CodexReviewer()
        default: return nil
        }
    }
}

/// Runs the selected reviewers in parallel and aggregates their verdicts.
public struct ReviewPanel: Sendable {
    public init() {}

    public func run(diff: String, reviewers: [Reviewer]) async -> (results: [ReviewResult], verdict: PanelVerdict) {
        var results: [ReviewResult] = []
        await withTaskGroup(of: ReviewResult.self) { group in
            for r in reviewers {
                group.addTask {
                    do {
                        let text = try await r.review(diff: diff)
                        return ReviewClassifier.classify(reviewer: r.name, text: text)
                    } catch {
                        return ReviewResult(reviewer: r.name, text: "reviewer error: \(error)",
                                            verdict: .unclear, blockers: 0, highs: 0)
                    }
                }
            }
            for await res in group { results.append(res) }
        }
        results.sort { $0.reviewer < $1.reviewer }
        return (results, ReviewClassifier.summarize(results))
    }
}
