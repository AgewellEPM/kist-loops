import Foundation

/// Shared trust boundary for durable-host configuration.
///
/// These files grant authority or bind an admitted name to executable host state. They therefore
/// receive the same treatment as credentials even when their values are not secret: one bounded,
/// owner-only regular file, reached through a descriptor-confined walk with no symlink following,
/// and decoded through the strict JSON ingress before any value can influence the runtime.
enum SMLHostConfigurationFile {
    static let maximumBytes = 1 * 1_024 * 1_024
    static let maximumBindings = 256
    static let maximumListEntries = 1_024
    static let maximumReferenceBytes = 4_096
    static let maximumShortStringBytes = 512
    static let maximumLongStringBytes = 64 * 1_024

    enum ReadError: Error, Equatable {
        case missing
        case unsafe(String)
    }

    struct SchemaError: Error, Equatable, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    static func read(projectRoot: String, relativePath: String) throws -> Data {
        do {
            let root = try ConfinedRoot(root: projectRoot, readOnly: true)
            return try root.readStableOwnerOnlyData(
                relativePath,
                maxBytes: maximumBytes,
                permissions: 0o600
            )
        } catch ToolError.notFound {
            throw ReadError.missing
        } catch {
            throw ReadError.unsafe(String(describing: error))
        }
    }

    static func read(fileURL: URL) throws -> Data {
        let parent = fileURL.deletingLastPathComponent()
        let leaf = fileURL.lastPathComponent
        guard !leaf.isEmpty else {
            throw ReadError.unsafe("configuration path does not name a file")
        }
        return try read(projectRoot: parent.path, relativePath: leaf)
    }

    static func decodeRoot(from data: Data) throws -> SMLObject {
        do {
            return try SMLWireCodec.decodeArbitraryJSONObject(
                from: data,
                limits: .init(
                    maximumBytes: maximumBytes,
                    maximumDepth: 16,
                    maximumNodes: 20_000
                )
            )
        } catch {
            throw SchemaError(reason: String(describing: error))
        }
    }

    static func requireOnlyKeys(
        _ object: SMLObject,
        allowed: Set<String>,
        path: String
    ) throws {
        if let key = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw SchemaError(reason: "unknown field '\(key)' at \(path)")
        }
    }

    static func requiredObject(_ value: SMLValue?, path: String) throws -> SMLObject {
        guard case .object(let object)? = value else {
            throw SchemaError(reason: "\(path) must be an object")
        }
        return object
    }

    static func optionalObject(_ value: SMLValue?, path: String) throws -> SMLObject? {
        guard let value else { return nil }
        guard case .object(let object) = value else {
            throw SchemaError(reason: "\(path) must be an object")
        }
        return object
    }

    static func requiredArray(_ value: SMLValue?, path: String) throws -> [SMLValue] {
        guard case .array(let values)? = value else {
            throw SchemaError(reason: "\(path) must be an array")
        }
        return values
    }

    static func optionalArray(_ value: SMLValue?, path: String) throws -> [SMLValue]? {
        guard let value else { return nil }
        guard case .array(let values) = value else {
            throw SchemaError(reason: "\(path) must be an array")
        }
        return values
    }

    static func requiredString(_ value: SMLValue?, path: String) throws -> String {
        guard case .string(let string)? = value else {
            throw SchemaError(reason: "\(path) must be a string")
        }
        return string
    }

    static func optionalString(_ value: SMLValue?, path: String) throws -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value else {
            throw SchemaError(reason: "\(path) must be a string")
        }
        return string
    }

    static func requiredInteger(_ value: SMLValue?, path: String) throws -> Int {
        guard case .number(let number)? = value, let integer = exactInt(number) else {
            throw SchemaError(reason: "\(path) must be an exact integer")
        }
        return integer
    }

    static func optionalInteger(_ value: SMLValue?, path: String) throws -> Int? {
        guard let value else { return nil }
        guard case .number(let number) = value, let integer = exactInt(number) else {
            throw SchemaError(reason: "\(path) must be an exact integer")
        }
        return integer
    }

    static func optionalBool(_ value: SMLValue?, path: String) throws -> Bool? {
        guard let value else { return nil }
        guard case .bool(let bool) = value else {
            throw SchemaError(reason: "\(path) must be a boolean")
        }
        return bool
    }

    static func boundedText(
        _ value: String,
        path: String,
        maximumBytes: Int,
        allowEmpty: Bool = false,
        allowFormattingWhitespace: Bool = false
    ) throws -> String {
        guard value.utf8.count <= maximumBytes,
              (allowEmpty || !value.isEmpty),
              (allowEmpty || value == value.trimmingCharacters(in: .whitespacesAndNewlines)),
              !value.unicodeScalars.contains(where: { scalar in
                  if allowFormattingWhitespace,
                     scalar == "\t" || scalar == "\n" || scalar == "\r" {
                      return false
                  }
                  return scalar.value < 0x20 || scalar.value == 0x7f
                      || (scalar.value >= 0x80 && scalar.value <= 0x9f)
              }) else {
            throw SchemaError(
                reason: "\(path) must contain \(allowEmpty ? "0" : "1")...\(maximumBytes) "
                    + "UTF-8 bytes without unsupported control characters"
            )
        }
        return value
    }

    static func reference(_ value: String, path: String) throws -> String {
        try boundedText(value, path: path, maximumBytes: maximumReferenceBytes)
    }

    static func stringArray(
        _ value: SMLValue?,
        path: String,
        maximumCount: Int = maximumListEntries,
        validate: (String, String) throws -> Void
    ) throws -> [String] {
        let values = try requiredArray(value, path: path)
        guard values.count <= maximumCount else {
            throw SchemaError(reason: "\(path) exceeds \(maximumCount) entries")
        }
        var seen = Set<String>()
        var output: [String] = []
        output.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            let itemPath = "\(path)[\(index)]"
            let string = try requiredString(value, path: itemPath)
            try validate(string, itemPath)
            guard seen.insert(string).inserted else {
                throw SchemaError(reason: "duplicate value '\(string)' at \(itemPath)")
            }
            output.append(string)
        }
        return output
    }

    private static func exactInt(_ decimal: Decimal) -> Int? {
        guard decimal.isFinite,
              decimal >= Decimal(Int.min), decimal <= Decimal(Int.max) else { return nil }
        var input = decimal
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        guard input == rounded else { return nil }
        return NSDecimalNumber(decimal: input).intValue
    }
}
