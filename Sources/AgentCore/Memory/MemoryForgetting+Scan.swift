import Foundation

extension MemoryForgetting {
    /// An application read budget, not an OS-enforced whole-run resource limit.
    static let maximumDirectoryBytes = 16 * 1_024 * 1_024

    struct DirectorySnapshot {
        var files: [String: Data] = [:]
        var issues: [String] = []
        var complete: Bool { issues.isEmpty }
    }

    static func snapshot(_ directory: String, store: String,
                         confined: ConfinedRoot) -> DirectorySnapshot {
        var result = DirectorySnapshot()
        do {
            let entries: [(name: String, isDir: Bool)]
            do { entries = try confined.entries(directory) }
            catch ToolError.notFound { return result }
            guard entries.count <= maximumScanRecords else {
                result.issues = ["\(store) inventory exceeds the scan limit; incomplete"]
                return result
            }
            var total = 0
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                guard !entry.isDir else {
                    result.issues.append("\(store) contains an unexpected directory; incomplete")
                    return result
                }
                let data = try confined.readStableData(directory + "/" + entry.name,
                                                        maxBytes: Procedure.maximumRecordBytes)
                total += data.count
                guard total <= maximumDirectoryBytes,
                      String(data: data, encoding: .utf8) != nil else {
                    result.issues.append("\(store) exceeds the byte budget or contains invalid text; incomplete")
                    return result
                }
                result.files[entry.name] = data
            }
            guard try confined.entries(directory).map(\.name).sorted() == entries.map(\.name).sorted() else {
                result.issues.append("\(store) inventory changed during the scan; incomplete")
                return result
            }
        } catch {
            // Do not copy a potentially sensitive filename or payload into a deletion receipt.
            result.issues.append("\(store) inventory or record unreadable; incomplete")
        }
        return result
    }

    /// JSON escapes must not hide text from an explicit deletion request. Raw matching also
    /// catches malformed rows without treating them as valid current memory.
    static func contentContains(_ data: Data, term: String) -> Bool {
        if String(decoding: data, as: UTF8.self).lowercased().contains(term) { return true }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return false }
        return stringsContain(object, term: term)
    }

    private static func stringsContain(_ object: Any, term: String) -> Bool {
        if let value = object as? String { return value.lowercased().contains(term) }
        if let values = object as? [Any] { return values.contains { stringsContain($0, term: term) } }
        if let values = object as? [String: Any] {
            return values.contains { $0.key.lowercased().contains(term) || stringsContain($0.value, term: term) }
        }
        return false
    }

    struct ResidualScan {
        var contains = false
        var issues: [String] = []
        var clean: Bool? { issues.isEmpty ? !contains : nil }
    }

    /// Point-in-time coverage of these three stores only. Missing stores are empty; failed,
    /// truncated, linked, malformed or changing reads cannot establish absence.
    static func residualScan(term: String, hostRoot: String) -> ResidualScan {
        var result = ResidualScan()
        do {
            let confined = try ConfinedRoot(root: hostRoot, readOnly: true)
            do {
                let data = try confined.readStableData(".mythos/memory/episodes.jsonl",
                                                       maxBytes: ProjectMemory.defaultMaxEpisodeBytes)
                guard String(data: data, encoding: .utf8) != nil else {
                    result.issues.append("episode residual scan contains invalid text; incomplete")
                    return result
                }
                for row in data.split(separator: 0x0A) {
                    let bytes = Data(row)
                    result.contains = result.contains || contentContains(bytes, term: term)
                    if (try? JSONSerialization.jsonObject(with: bytes)) == nil {
                        result.issues.append("episode residual scan contains malformed data; incomplete")
                        break
                    }
                }
            } catch ToolError.notFound {
                // Absent is distinct from unreadable.
            } catch {
                result.issues.append("episode residual scan unreadable or over limit; incomplete")
            }
            for (directory, store) in [(ProcedureStore.directory, "procedure"),
                                       (MemoryReactivationStore.directory, "reactivation")] {
                let observed = snapshot(directory, store: store, confined: confined)
                result.issues.append(contentsOf: observed.issues)
                for bytes in observed.files.values {
                    result.contains = result.contains || contentContains(bytes, term: term)
                    if (try? JSONSerialization.jsonObject(with: bytes)) == nil {
                        result.issues.append("\(store) residual scan contains malformed data; incomplete")
                        break
                    }
                }
            }
        } catch {
            result.issues.append("host root unavailable for residual scan; incomplete")
        }
        return result
    }

    /// Compatibility predicate: uncertainty conservatively means residue cannot be ruled out.
    static func residualContains(term: String, hostRoot: String) -> Bool {
        residualScan(term: term.lowercased(), hostRoot: hostRoot).clean != true
    }
}
