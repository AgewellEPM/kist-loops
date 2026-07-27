import Foundation
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "JSONDirectoryStore")

/// Generic atomic per-item JSON store: one `<id>.json` file per item.
///
/// Writes are atomic (temp file + replace) so a crash mid-write never leaves a
/// half-serialized, un-loadable file. Corrupt files are skipped in `list()`,
/// never thrown. Shared by the agent checkpoint store and the orchestration
/// checkpoint store so the durability logic lives in exactly one place.
final class JSONDirectoryStore<T: Codable & Identifiable> where T.ID == String {
    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var storageDirectory: URL { directory }
    func url(for id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    func save(_ item: T) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(item)
        let target = url(for: item.id)
        let temp = directory.appendingPathComponent("\(item.id).json.tmp")
        try data.write(to: temp, options: .atomic)
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: target)
        }
    }

    func load(id: String) throws -> T {
        let data = try Data(contentsOf: url(for: id))
        return try decoder.decode(T.self, from: data)
    }

    /// All items; corrupt files are skipped (and logged), never thrown.
    func list() -> [T] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var items: [T] = []
        for file in files where file.pathExtension == "json" {
            do {
                items.append(try decoder.decode(T.self, from: try Data(contentsOf: file)))
            } catch {
                logger.warning("Skipping unreadable item \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return items
    }

    func delete(id: String) throws {
        let target = url(for: id)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
    }

    /// Default `~/Library/Application Support/FloatingChatApp/<subfolder>/`.
    static func defaultDirectory(subfolder: String, fileManager: FileManager = .default) -> URL {
        let base = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("FloatingChatApp/\(subfolder)", isDirectory: true)
    }
}
