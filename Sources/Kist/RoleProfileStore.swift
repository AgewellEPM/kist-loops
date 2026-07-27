import Foundation
import AgentCore

/// Persistent named AI-team presets for the terminal surface.
///
/// Stored as JSON under XDG config (`~/.config/kist/roles.json` by default), so a user can
/// define a team once in the REPL and reuse it with `/roles load <name>` or `--roles <name>`.
struct RoleProfileStore {
    struct Profile: Codable, Equatable {
        var planner: String
        var worker: String
        var coder: String
        var critic: String

        init(planner: String, worker: String, coder: String, critic: String) {
            self.planner = planner
            self.worker = worker
            self.coder = coder
            self.critic = critic
        }

        init(bindings: RoleBindings) {
            self.init(
                planner: Self.render(bindings.binding(for: .planner)),
                worker: Self.render(bindings.binding(for: .worker)),
                coder: Self.render(bindings.binding(for: .coder)),
                critic: Self.render(bindings.binding(for: .critic))
            )
        }

        func binding(for role: AgentRole) -> ProviderBinding? {
            switch role {
            case .planner: return ProviderBinding.parse(planner)
            case .worker: return ProviderBinding.parse(worker)
            case .coder: return ProviderBinding.parse(coder)
            case .critic: return ProviderBinding.parse(critic)
            }
        }

        private static func render(_ binding: ProviderBinding) -> String {
            binding.providerId + (binding.model.map { ":\($0)" } ?? "")
        }
    }

    enum StoreError: Error, CustomStringConvertible, Equatable {
        case invalidName(String)
        case profileMissing(String)
        case cannotRead(String)
        case cannotWrite(String)

        var description: String {
            switch self {
            case .invalidName(let name):
                return "invalid role profile name '\(name)' (use letters, numbers, '.', '_', or '-')"
            case .profileMissing(let name):
                return "role profile '\(name)' not found"
            case .cannotRead(let message):
                return "could not read role profiles: \(message)"
            case .cannotWrite(let message):
                return "could not write role profiles: \(message)"
            }
        }
    }

    private struct FileFormat: Codable {
        var profiles: [String: Profile]
    }

    let path: String

    init(path: String = RoleProfileStore.defaultPath()) {
        self.path = path
    }

    static func defaultPath() -> String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? (NSHomeDirectory() + "/.config")
        return base + "/kist/roles.json"
    }

    func names() throws -> [String] {
        try loadAll().keys.sorted()
    }

    func profile(named name: String) throws -> Profile {
        let key = try validateName(name)
        guard let profile = try loadAll()[key] else { throw StoreError.profileMissing(name) }
        return profile
    }

    func save(_ profile: Profile, named name: String) throws {
        let key = try validateName(name)
        var profiles = try loadAll()
        profiles[key] = profile
        try writeAll(profiles)
    }

    @discardableResult
    func delete(named name: String) throws -> Bool {
        let key = try validateName(name)
        var profiles = try loadAll()
        guard profiles.removeValue(forKey: key) != nil else { return false }
        try writeAll(profiles)
        return true
    }

    private func loadAll() throws -> [String: Profile] {
        guard FileManager.default.fileExists(atPath: path) else {
            return [:]
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode(FileFormat.self, from: data).profiles
        } catch {
            throw StoreError.cannotRead(error.localizedDescription)
        }
    }

    private func writeAll(_ profiles: [String: Profile]) throws {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(FileFormat(profiles: profiles))
            try data.write(to: url, options: [.atomic])
        } catch {
            throw StoreError.cannotWrite(error.localizedDescription)
        }
    }

    private func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard trimmed == name, !trimmed.isEmpty, trimmed.count <= 64,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw StoreError.invalidName(name)
        }
        return trimmed
    }
}
