import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Only local-first opts in. Stored weights are reused offline; missing approved artifacts
/// are fetched once per process/model, with metadata, disk, size and digest checks.
actor OllamaModelAcquisition {
    static let shared = OllamaModelAcquisition()
    private struct Download {
        let id = UUID()
        let task: Task<Void, Error>
        var waiters: Set<UUID>
    }
    private var pending: [String: Download] = [:]
    private var failures: [String: Date] = [:]
    private let prepareOperation: @Sendable (ManagedLocalModel, URL) async throws -> Void
    private let hostResources: @Sendable () -> (UInt64, Int)

    init(prepare: @escaping @Sendable (ManagedLocalModel, URL) async throws -> Void = {
        try await OllamaModelAcquisition.prepare($0, chatURL: $1)
    }, hostResources: @escaping @Sendable () -> (UInt64, Int) = {
        (ProcessInfo.processInfo.physicalMemory, ManagedLocalModel.hostMemoryPressure())
    }) {
        self.prepareOperation = prepare
        self.hostResources = hostResources
    }

    func ensure(model: String, endpoint: String) async throws {
        guard let candidate = ManagedLocalModel.lookup(model) else { return }
        guard let url = URL(string: endpoint), ManagedLocalModel.isLoopback(url) else {
            throw unavailable("automatic acquisition requires a loopback Ollama server")
        }
        let (memory, pressure) = hostResources()
        guard candidate.fits(memoryBytes: memory, memoryPressure: pressure) else {
            throw unavailable("\(model) exceeds host memory capacity or current memory pressure")
        }
        let key = endpoint + "|" + model
        if let failure = failures[key], Date().timeIntervalSince(failure) < 30 {
            throw unavailable("recent acquisition failure; cooling down before retry")
        }
        try Task.checkCancellation()
        let waiter = UUID()
        let prepare = prepareOperation
        var download = pending[key] ?? Download(
            task: Task { try await prepare(candidate, url) }, waiters: [])
        download.waiters.insert(waiter)
        pending[key] = download
        let task = download.task
        let downloadID = download.id
        do {
            try await withTaskCancellationHandler {
                try await task.value
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.release(key, downloadID: downloadID, waiter: waiter) }
            }
            release(key, downloadID: downloadID, waiter: waiter)
            failures[key] = nil
        } catch {
            release(key, downloadID: downloadID, waiter: waiter)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            failures[key] = Date()
            if let providerError = error as? AIProviderError { throw providerError }
            throw unavailable(String(String(describing: error).prefix(300)))
        }
    }

    /// Cancelling one caller must not cancel a download another caller still needs.
    private func release(_ key: String, downloadID: UUID, waiter: UUID) {
        guard var download = pending[key], download.id == downloadID else { return }
        download.waiters.remove(waiter)
        if download.waiters.isEmpty {
            download.task.cancel()
            pending[key] = nil
        } else { pending[key] = download }
    }

    static func prepare(_ candidate: ManagedLocalModel, chatURL: URL,
                        json: @Sendable (URL) async throws -> [String: Any] = { try await getJSON($0) },
                        download: @Sendable (ManagedLocalModel, URL) async throws -> Void = { try await pull($0, base: $1) },
                        freeBytes: () throws -> Int64 = availableDiskBytes) async throws {
        let base = chatURL.deletingLastPathComponent()
        let tagsURL = base.appendingPathComponent("tags")
        if let installed = try await installedDigest(candidate.model, at: tagsURL, json: json) {
            guard installed == candidate.manifestDigest else {
                throw unavailable("installed \(candidate.model) differs from the qualified artifact; run model vet/onboard")
            }
            return
        }
        try Task.checkCancellation()
        let metadataURL = URL(string: "https://huggingface.co/api/models/\(candidate.huggingFaceRepo)")!
        let metadata = try await json(metadataURL)
        guard ManagedLocalModel.validateMetadata(metadata, candidate: candidate) else {
            throw unavailable("Hugging Face provenance/license metadata did not pass for \(candidate.model)")
        }
        guard try freeBytes() >= candidate.maximumDownloadBytes + 2 * 1_073_741_824 else {
            throw unavailable("insufficient disk space for \(candidate.model)")
        }
        try await download(candidate, base)
        guard try await installedDigest(candidate.model, at: tagsURL, json: json) == candidate.manifestDigest else {
            throw unavailable("download did not yield the qualified model digest; no inference started")
        }
    }

    static func availableDiskBytes() throws -> Int64 {
        // Follow the user's model-store symlink; check the destination filesystem, not cwd.
        let env = ProcessInfo.processInfo.environment
        var storage = URL(fileURLWithPath: env["OLLAMA_MODELS"]
                          ?? NSHomeDirectory() + "/.ollama/models").resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath: storage.path), storage.path != "/" {
            storage.deleteLastPathComponent()
        }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: storage.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    static func pull(_ candidate: ManagedLocalModel, base: URL) async throws {
        FileHandle.standardError.write(Data(("local model · downloading qualified \(candidate.model) on demand\n").utf8))
        var request = URLRequest(url: base.appendingPathComponent("pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": candidate.model, "stream": true])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw unavailable("model pull failed") }
        var progress = LocalModelPullProgress(maximumBytes: candidate.maximumDownloadBytes)
        let start = Date()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(start) <= 600 else { throw unavailable("model pull deadline reached") }
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try progress.consume(Data(line.utf8))
            }
        }
        guard progress.complete else { throw unavailable("model download ended without a completion record") }
    }

    private static func installedDigest(_ model: String, at url: URL,
                                        json: @Sendable (URL) async throws -> [String: Any]) async throws -> String? {
        let json = try await json(url)
        guard let models = json["models"] as? [[String: Any]] else { throw unavailable("invalid Ollama inventory") }
        guard let entry = models.first(where: { $0["name"] as? String == model }) else { return nil }
        guard let digest = entry["digest"] as? String else { throw unavailable("installed model has no digest") }
        return digest
    }

    static func getJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw unavailable("model metadata request failed") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 2_097_152 else { throw unavailable("model metadata exceeds limit") }
            data.append(byte)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw unavailable("model metadata is not an object")
        }
        return json
    }

    private nonisolated static func unavailable(_ reason: String) -> AIProviderError {
        .transport("Local model unavailable: " + reason)
    }
    private nonisolated func unavailable(_ reason: String) -> AIProviderError { Self.unavailable(reason) }
}
