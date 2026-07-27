import Foundation

/// On-disk record for a user-added OpenAI-compatible provider. Persisted to
/// `~/.kist/providers.json` as a JSON array. The API KEY never lives here — it is
/// written separately by `SecretWriter` to the 0600 key file. This file is config
/// only (endpoint, model list, detected capabilities) and is safe at normal perms.
public struct CustomProviderRecord: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var iconName: String
    public var keyAccount: String
    public var endpoint: String
    public var defaultModel: String
    public var availableModels: [AIModel]
    public var requiresAPIKey: Bool
    public var isLocal: Bool
    /// Empirically detected during onboarding (the MiMo/DeepSeek round-2 signature).
    public var nativeToolsSupported: Bool

    public init(id: String, name: String, iconName: String = "plus.app", keyAccount: String,
                endpoint: String, defaultModel: String, availableModels: [AIModel],
                requiresAPIKey: Bool = true, isLocal: Bool = false, nativeToolsSupported: Bool = true) {
        self.id = id; self.name = name; self.iconName = iconName; self.keyAccount = keyAccount
        self.endpoint = endpoint; self.defaultModel = defaultModel; self.availableModels = availableModels
        self.requiresAPIKey = requiresAPIKey; self.isLocal = isLocal; self.nativeToolsSupported = nativeToolsSupported
    }

    /// Build the live provider this record describes.
    public func makeProvider() -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            id: id, name: name, iconName: iconName, keyAccount: keyAccount,
            endpoint: endpoint, defaultModel: defaultModel,
            availableModels: availableModels.isEmpty ? [AIModel(id: defaultModel)] : availableModels,
            requiresAPIKey: requiresAPIKey, isLocal: isLocal, nativeToolsSupported: nativeToolsSupported)
    }

    /// Snapshot a configured provider back into a persistable record.
    public init(provider p: OpenAICompatibleProvider) {
        self.init(id: p.id, name: p.name, iconName: p.iconName, keyAccount: p.keyAccount,
                  endpoint: p.endpoint, defaultModel: p.defaultModel, availableModels: p.availableModels,
                  requiresAPIKey: p.requiresAPIKey, isLocal: p.isLocal, nativeToolsSupported: p.nativeToolsSupported)
    }
}

/// Load/save user-added providers. Pure file I/O — fail-soft on read (a broken file
/// yields an empty list, never a crash), strict on write.
public enum CustomProviderStore {
    /// Built-in provider ids a custom provider may NOT shadow (would confuse `provider(id:)`).
    /// Lowercased at construction so the case-insensitive checks hold even for a future mixed-case built-in.
    public static var reservedIds: Set<String> { Set(ProviderCatalog.all.map { $0.id.lowercased() }) }

    public static func defaultPath() -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return home + "/.kist/providers.json"
    }

    /// Read records; a missing/corrupt file is treated as "none configured" (fail-soft).
    public static func loadRecords(path: String = defaultPath()) -> [CustomProviderRecord] {
        guard let data = FileManager.default.contents(atPath: path),
              let records = try? JSONDecoder().decode([CustomProviderRecord].self, from: data)
        else { return [] }
        // Defensive: drop any record that collides with a built-in id (case-insensitive), and
        // canonicalize surviving ids to lowercase so all downstream lookups are stable.
        let reserved = reservedIds
        return records.filter { !reserved.contains($0.id.lowercased()) }
                      .map { var r = $0; r.id = r.id.lowercased(); return r }
    }

    /// The custom providers, ready to merge into a `ProviderRegistry`.
    public static func load(path: String = defaultPath()) -> [OpenAICompatibleProvider] {
        loadRecords(path: path).map { $0.makeProvider() }
    }

    /// Whether `id` is free to use (not reserved, not already taken by a custom provider).
    /// Case-insensitive: ids are canonicalized to lowercase so `OpenAI` can't shadow `openai`.
    public static func isIdAvailable(_ id: String, path: String = defaultPath()) -> Bool {
        let lower = id.lowercased()
        return !reservedIds.contains(lower) && !loadRecords(path: path).contains { $0.id.lowercased() == lower }
    }

    public enum StoreError: Error, Equatable {
        case reservedId(String)
        case writeFailed(String)
    }

    /// Insert or replace a record by id, then persist. Rejects reserved ids (case-insensitive).
    /// Canonicalizes the id to lowercase so it can never shadow a built-in via case.
    public static func upsert(_ record: CustomProviderRecord, path: String = defaultPath()) throws {
        var record = record
        record.id = record.id.lowercased()
        guard !reservedIds.contains(record.id) else { throw StoreError.reservedId(record.id) }
        var records = loadRecords(path: path).filter { $0.id.lowercased() != record.id }
        records.append(record)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(records).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw StoreError.writeFailed("\(error)")
        }
    }

    /// Remove a custom provider by id (no-op if absent). Returns true if something was removed.
    @discardableResult
    public static func remove(id: String, path: String = defaultPath()) -> Bool {
        let before = loadRecords(path: path)
        let after = before.filter { $0.id != id }
        guard after.count != before.count else { return false }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(after) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        return true
    }
}
