import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Metadata only: never pulls, preloads, probes generation, scans the LAN or starts a cluster.
enum OllamaAdmission {
    typealias Fetch = (URL, [String: String]?) async throws -> [String: Any]

    static func report(endpoint: URL, model: String, context: Int,
                       memory: () -> LocalModelMemory = LocalModelMemory.current,
                       fetch: Fetch = readJSON) async throws -> LocalModelAdmission {
        var host = memory()
        func blocked(_ reason: String) -> LocalModelAdmission {
            .blocked(model: model, memory: host, context: context, reason: reason)
        }
        guard ManagedLocalModel.isLoopback(endpoint) else {
            return blocked("remote server capacity cannot be inferred from this Mac; distributed placement is not configured")
        }
        guard (256...131_072).contains(context) else { return blocked("context must be 256...131072 tokens") }
        guard host.requestBudgetBytes > 0 else { return blocked("host memory pressure or unavailable memory measurement") }
        let base = endpoint.deletingLastPathComponent()
        let name = model.split(separator: "/").last?.contains(":") == true ? model : model + ":latest"
        let tags = try await fetch(base.appendingPathComponent("tags"), nil)
        guard let entry = (tags["models"] as? [[String: Any]])?.first(where: { $0["name"] as? String == name }),
              let size = LocalModelAdmission.positive(entry["size"], max: 1024 * LocalModelMemory.gib),
              let digest = entry["digest"] as? String, !digest.isEmpty else {
            return blocked("selected model has no installed size and identity metadata")
        }
        // /api/tags size describes the whole model, including all layers/shards, not one file.
        guard size < host.requestBudgetBytes else {
            return .blocked(model: model, memory: host, context: context,
                            reason: "total model weights exceed the current single-host memory budget", weights: size)
        }
        let shown = try await fetch(base.appendingPathComponent("show"), ["model": name])
        guard let info = shown["model_info"] as? [String: Any],
              (shown["projector_info"] as? [String: Any] ?? [:]).isEmpty,
              !(shown["capabilities"] as? [String] ?? []).contains("vision") else {
            return blocked("missing text-model metadata or unsupported multimodal memory allocation")
        }
        // An external client can change a tag while metadata is being read. Reject that race.
        let refreshed = try await fetch(base.appendingPathComponent("tags"), nil)
        guard let actual = (refreshed["models"] as? [[String: Any]])?.first(where: { $0["name"] as? String == name }),
              actual["digest"] as? String == digest,
              LocalModelAdmission.positive(actual["size"], max: 1024 * LocalModelMemory.gib) == size else {
            return blocked("model identity changed during memory admission")
        }
        host = memory() // Metadata calls may have taken seconds; never admit on a stale snapshot.
        return .evaluate(model: model, weights: size, info: info, context: context, memory: host)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    static func readJSON(_ url: URL, body: [String: String]?) async throws -> [String: Any] {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        // Local metadata must never go through an environment/system proxy or follow redirects.
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AIProviderError.transport("Local model metadata unavailable; no inference started")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 2_097_152 else {
                throw AIProviderError.transport("Local model metadata exceeds 2 MiB; no inference started")
            }
            data.append(byte)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.transport("Local model metadata is not an object; no inference started")
        }
        return object
    }
}

extension OllamaProvider {
    /// Read-only diagnostic uses the same gate as inference. It does not acquire a model.
    public func memoryAdmission(model: String, context: Int? = nil) async throws -> LocalModelAdmission {
        guard let url = URL(string: endpoint) else { throw AIProviderError.configuration("bad local endpoint") }
        return try await OllamaAdmission.report(endpoint: url, model: model,
            context: context ?? capabilities(forModel: model).contextWindowTokens ?? 4096)
    }

    func admittedBody(_ body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: endpoint), ManagedLocalModel.isLoopback(url) else { return body }
        var body = body
        var options = body["options"] as? [String: Any] ?? [:]
        let context = options["num_ctx"] as? Int ?? 4096
        options["num_ctx"] = context // Never rely on a daemon's potentially enormous default.
        body["options"] = options
        try validateContextEstimate(body)
        let report = try await memoryAdmission(model: body["model"] as? String ?? "", context: context)
        guard report.admitted else { throw report.providerError }
        return body
    }
}
