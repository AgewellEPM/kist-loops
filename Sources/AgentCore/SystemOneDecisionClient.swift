import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The local Ollama Jev-compatible protocol. Endpoint/model are host configuration,
/// never arguments accepted from model-generated question sets or manifests.
public struct SystemOneDecisionClient: Sendable {
    public let endpoint: URL
    public let model: String
    public init(baseURL: String = "http://127.0.0.1:11434", model: String) throws {
        guard let url = URL(string: baseURL), url.scheme == "http",
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              model.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}\z"#, options: .regularExpression) != nil else {
            throw ToolError.configuration("SystemOne requires an explicit model and a loopback HTTP base URL")
        }
        self.endpoint = url.appendingPathComponent("v1/systemone"); self.model = model
    }

    func requestBody(_ capsule: String) throws -> Data {
        guard let body = try JSONSerialization.jsonObject(with: Data(capsule.utf8)) as? [String: Any],
              let questions = body["questions"] as? [String: [String: Any]], let state = body["state"] else {
            throw ToolError.invalidParameter("invalid decision capsule")
        }
        var native: [String: Any] = [:]
        for (name, question) in questions {
            guard let type = question["type"] as? String, let instructions = question["instructions"] as? String,
                  let options = question["options"] as? [String: String] else { throw ToolError.invalidParameter("invalid question") }
            let criteria: Any = type == "score"
                ? options.keys.sorted { (Int($0) ?? -1) < (Int($1) ?? -1) }.compactMap { options[$0] } as Any : options
            native[name] = ["type": type, "instructions": instructions, "criteria": criteria]
        }
        _ = try DecisionQuestion.parseAll(native)
        let data = Data(try DecisionEngine.json(["model": model, "state": state, "questions": native]).utf8)
        guard data.count <= DecisionEngine.maxRequestBytes else { throw ToolError.invalidParameter("SystemOne request exceeds 64 KiB") }
        return data
    }

    public func infer(_ capsule: String, maxTokens: Int) async throws -> DecisionInference {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try requestBody(capsule)
        if let budget = DecisionRequestScope.budget { try await budget.admit() }
        // Reuse the bounded cross-platform transport: caps streaming bytes even
        // without Content-Length, refuses redirects, and disables proxies/cookies.
        let response = try await SMLHTTPURLSessionTransport().send(request, timeoutSeconds: 45,
                                                                  maximumResponseBytes: 128 * 1024)
        guard response.statusCode == 200 else {
            throw ToolError.execution("SystemOne request failed (HTTP \(response.statusCode)); requires Ollama with /v1/systemone and the configured model installed")
        }
        return try decode(response.body)
    }

    func decode(_ data: Data) throws -> DecisionInference {
        guard data.count <= 128 * 1024,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let returnedModel = body["model"] as? String, [model, model + ":latest"].contains(returnedModel),
              var answers = body["answers"] as? [String: [String: Any]] else {
            throw ToolError.execution("invalid SystemOne response or unexpected model")
        }
        for name in answers.keys {
            if answers[name]?["type"] as? String == "noul" {
                guard let number = answers[name]?["noul"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      (0...1).contains(number.doubleValue) else {
                    throw ToolError.execution("invalid SystemOne boolean probability")
                }
                answers[name]?["probabilities"] = ["true": number.doubleValue, "false": 1 - number.doubleValue]
            }
        }
        body["answers"] = answers
        func tokenCount(_ key: String) throws -> Int {
            guard let value = (body["usage"] as? [String: Any])?[key] else { return 0 }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...10_000_000).contains(number.doubleValue),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else {
                throw ToolError.execution("invalid SystemOne usage")
            }
            return number.intValue
        }
        return DecisionInference(text: try DecisionEngine.json(body),
                                 usage: TokenUsage(promptTokens: try tokenCount("input_tokens"), completionTokens: try tokenCount("output_tokens")))
    }
}

public extension DecisionEngine {
    static func configured(providers: ProviderRegistry, binding: ProviderBinding,
                           budget: BudgetLedger? = nil, sink: RuntimeEventSink? = nil, recorder: TraceRecorder? = nil,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> DecisionEngine {
        guard let backend = environment["KIST_DECISION_BACKEND"], backend != "provider" else {
            return bound(providers: providers, binding: binding, budget: budget, sink: sink, recorder: recorder)
        }
        do {
            guard backend == "systemone", let model = environment["KIST_DECISION_MODEL"] else {
                throw ToolError.configuration("use KIST_DECISION_BACKEND=systemone with KIST_DECISION_MODEL, or provider")
            }
            let client = try SystemOneDecisionClient(baseURL: environment["KIST_DECISION_BASE_URL"] ?? "http://127.0.0.1:11434", model: model)
            return DecisionEngine(provider: "ollama", model: model, probabilitySource: "answer_token_scores",
                                  budget: budget, sink: sink, recorder: recorder, infer: { try await client.infer($0, maxTokens: $1) })
        } catch {
            let reason = String(describing: error)
            return DecisionEngine(provider: "unavailable", model: "unavailable", budget: budget, sink: sink,
                                  unavailableReason: reason) { _, _ in
                throw ToolError.configuration(reason)
            }
        }
    }
}
