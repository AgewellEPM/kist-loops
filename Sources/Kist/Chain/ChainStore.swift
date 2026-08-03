import Foundation

/// Durable store for chains: one JSON file per chain under `<projectRoot>/.kist/chains/`. The web canvas,
/// the `/chain` command, and the headless runner all read/write through here so there's one source of truth.
struct ChainStore {
    let projectRoot: String
    private var dir: String { projectRoot + "/.kist/chains" }
    private func path(_ id: String) -> String { dir + "/\(id).json" }

    init(projectRoot: String) { self.projectRoot = projectRoot }

    func all() -> [Chain] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> Chain? in
                guard let data = FileManager.default.contents(atPath: dir + "/" + name) else { return nil }
                return try? JSONDecoder().decode(Chain.self, from: data)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func load(id: String) -> Chain? {
        guard let data = FileManager.default.contents(atPath: path(id)) else { return nil }
        return try? JSONDecoder().decode(Chain.self, from: data)
    }

    /// Find by exact id, else by case-insensitive name (so `/chain run daily-email` works).
    func find(_ ref: String) -> Chain? {
        if let c = load(id: ref) { return c }
        return all().first { $0.name.lowercased() == ref.lowercased() || $0.id == ref }
    }

    @discardableResult
    func save(_ chain: Chain) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(chain) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path(chain.id)))) != nil
    }

    @discardableResult
    func delete(id: String) -> Bool {
        (try? FileManager.default.removeItem(atPath: path(id))) != nil
    }
}
