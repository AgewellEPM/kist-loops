import Foundation

/// A bounded, explicit JSON Schema subset for model output. Legacy type-only string
/// bindings keep their plain-text behavior; object-form schemas always parse JSON.
public struct SMLModelOutputContract: Sendable {
    public let type: SMLStateType
    public let jsonSchema: SMLObject
    public let compactJSON: String
    let acceptsPlainText: Bool
    private let node: Node

    public init(type: SMLStateType) {
        self.type = type
        self.jsonSchema = ["type": .string(type.rawValue)]
        self.compactJSON = "{\"type\":\"\(type.rawValue)\"}"
        self.acceptsPlainText = type == .string
        self.node = Node.unconstrained(type)
    }

    public init(schema: SMLObject) throws {
        var nodes = 0
        let node = try Self.compile(schema, path: "output_schema", depth: 0, nodes: &nodes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(schema)
        guard data.count <= 16_384 else {
            throw SMLModelOutputContractError.invalidSchema(path: "output_schema", reason: "compact schema exceeds 16384 bytes")
        }
        self.type = node.type
        self.jsonSchema = schema
        self.compactJSON = String(decoding: data, as: UTF8.self)
        self.acceptsPlainText = false
        self.node = node
    }

    public func validate(_ value: SMLValue) throws {
        try node.validate(value, path: "$")
    }

    private indirect enum Node: Sendable {
        case object(properties: [String: Node], required: [String], additional: Bool, min: Int?, max: Int?)
        case array(items: Node?, min: Int?, max: Int?)
        case string(min: Int?, max: Int?)
        case number(integer: Bool, min: Decimal?, max: Decimal?, exclusiveMin: Decimal?, exclusiveMax: Decimal?)
        case boolean

        var type: SMLStateType {
            switch self {
            case .object: return .object
            case .array: return .array
            case .string: return .string
            case .number(let integer, _, _, _, _): return integer ? .integer : .number
            case .boolean: return .boolean
            }
        }

        static func unconstrained(_ type: SMLStateType) -> Node {
            switch type {
            case .object: return .object(properties: [:], required: [], additional: true, min: nil, max: nil)
            case .array: return .array(items: nil, min: nil, max: nil)
            case .string: return .string(min: nil, max: nil)
            case .number, .integer: return .number(integer: type == .integer, min: nil, max: nil, exclusiveMin: nil, exclusiveMax: nil)
            case .boolean: return .boolean
            }
        }

        func validate(_ value: SMLValue, path: String) throws {
            func mismatch(_ reason: String) -> SMLModelOutputContractError {
                .mismatch(path: path, reason: reason)
            }
            func length(_ count: Int, _ min: Int?, _ max: Int?) throws {
                if let min, count < min { throw mismatch("length \(count) is below minimum \(min)") }
                if let max, count > max { throw mismatch("length \(count) exceeds maximum \(max)") }
            }
            switch (self, value) {
            case (.object(let properties, let required, let additional, let min, let max), .object(let values)):
                try length(values.count, min, max)
                for name in required where values[name] == nil {
                    throw mismatch("missing required property '\(name)'")
                }
                for name in values.keys.sorted() {
                    if let child = properties[name], let value = values[name] {
                        try child.validate(value, path: "\(path).\(name)")
                    } else if !additional {
                        throw mismatch("additional property '\(name)' is not allowed")
                    }
                }
            case (.array(let items, let min, let max), .array(let values)):
                try length(values.count, min, max)
                if let items {
                    for (index, value) in values.enumerated() {
                        try items.validate(value, path: "\(path)[\(index)]")
                    }
                }
            case (.string(let min, let max), .string(let text)):
                // JSON Schema lengths count Unicode code points, not grapheme clusters or UTF-8 bytes.
                try length(text.unicodeScalars.count, min, max)
            case (.number(let integer, let min, let max, let exclusiveMin, let exclusiveMax), .number(let number)):
                guard number.isFinite else { throw mismatch("number must be finite") }
                if integer {
                    var original = number
                    var rounded = Decimal()
                    NSDecimalRound(&rounded, &original, 0, .plain)
                    guard rounded == number else { throw mismatch("expected integer") }
                }
                if let min, number < min { throw mismatch("number is below minimum \(min)") }
                if let max, number > max { throw mismatch("number exceeds maximum \(max)") }
                if let exclusiveMin, number <= exclusiveMin { throw mismatch("number must exceed \(exclusiveMin)") }
                if let exclusiveMax, number >= exclusiveMax { throw mismatch("number must be below \(exclusiveMax)") }
            case (.boolean, .bool): break
            default: throw mismatch("expected \(type.rawValue)")
            }
        }
    }

    private static func compile(_ schema: SMLObject, path: String, depth: Int, nodes: inout Int) throws -> Node {
        nodes += 1
        func invalid(_ reason: String) -> SMLModelOutputContractError {
            .invalidSchema(path: path, reason: reason)
        }
        guard depth <= 8, nodes <= 256 else { throw invalid("schema exceeds depth 8 or 256 nodes") }
        guard case .string(let rawType)? = schema["type"], let type = SMLStateType(rawValue: rawType) else {
            throw invalid("type must be one supported string: object, array, string, number, integer, boolean")
        }
        let allowed: Set<String>
        switch type {
        case .object: allowed = ["type", "properties", "required", "additionalProperties", "minProperties", "maxProperties"]
        case .array: allowed = ["type", "items", "minItems", "maxItems"]
        case .string: allowed = ["type", "minLength", "maxLength"]
        case .number, .integer: allowed = ["type", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"]
        case .boolean: allowed = ["type"]
        }
        if let key = schema.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw invalid("unsupported keyword '\(key)' for \(rawType)")
        }
        func bounds(_ minKey: String, _ maxKey: String, ceiling: Int) throws -> (Int?, Int?) {
            let min = try SMLHostConfigurationFile.optionalInteger(schema[minKey], path: "\(path).\(minKey)")
            let max = try SMLHostConfigurationFile.optionalInteger(schema[maxKey], path: "\(path).\(maxKey)")
            for bound in [min, max].compactMap({ $0 }) where !(0...ceiling).contains(bound) {
                throw invalid("\(minKey)/\(maxKey) must be within 0...\(ceiling)")
            }
            if let min, let max, min > max { throw invalid("\(minKey) exceeds \(maxKey)") }
            return (min, max)
        }
        switch type {
        case .object:
            let (min, max) = try bounds("minProperties", "maxProperties", ceiling: SMLValidationSupport.maximumObjectEntries)
            let raw = try SMLHostConfigurationFile.optionalObject(schema["properties"], path: "\(path).properties") ?? [:]
            guard raw.count <= 256 else { throw invalid("properties exceeds 256 entries") }
            var properties: [String: Node] = [:]
            for name in raw.keys.sorted() {
                guard SMLValidationSupport.identifierIsValid(name, maximumLength: 128) else {
                    throw invalid("property '\(name)' must be an SML state key of at most 128 characters")
                }
                let child = try SMLHostConfigurationFile.requiredObject(raw[name], path: "\(path).properties.\(name)")
                properties[name] = try compile(child, path: "\(path).properties.\(name)", depth: depth + 1, nodes: &nodes)
            }
            var required: [String] = []
            if let rawRequired = schema["required"] {
                required = try SMLHostConfigurationFile.stringArray(rawRequired, path: "\(path).required", maximumCount: 256) { name, _ in
                    guard properties[name] != nil else { throw invalid("required property '\(name)' must be declared in properties") }
                }
            }
            let additional = try SMLHostConfigurationFile.optionalBool(schema["additionalProperties"], path: "\(path).additionalProperties") ?? true
            if let max, required.count > max { throw invalid("required property count exceeds maxProperties") }
            if !additional, let min, min > properties.count { throw invalid("minProperties exceeds declared closed properties") }
            return .object(properties: properties, required: required.sorted(), additional: additional, min: min, max: max)
        case .array:
            let (min, max) = try bounds("minItems", "maxItems", ceiling: SMLValidationSupport.maximumArrayEntries)
            let items: Node?
            if let rawItems = schema["items"] {
                let child = try SMLHostConfigurationFile.requiredObject(rawItems, path: "\(path).items")
                items = try compile(child, path: "\(path).items", depth: depth + 1, nodes: &nodes)
            } else { items = nil }
            return .array(items: items, min: min, max: max)
        case .string:
            let (min, max) = try bounds("minLength", "maxLength", ceiling: SMLValidationSupport.maximumStringBytes)
            return .string(min: min, max: max)
        case .number, .integer:
            func number(_ key: String) throws -> Decimal? {
                guard let value = schema[key] else { return nil }
                guard case .number(let number) = value, number.isFinite else { throw invalid("\(key) must be a finite number") }
                return number
            }
            let min = try number("minimum"), max = try number("maximum")
            let exclusiveMin = try number("exclusiveMinimum"), exclusiveMax = try number("exclusiveMaximum")
            if let low = [min, exclusiveMin].compactMap({ $0 }).max(),
               let high = [max, exclusiveMax].compactMap({ $0 }).min(),
               low > high || (low == high && (exclusiveMin == low || exclusiveMax == high)) {
                throw invalid("numeric bounds admit no value")
            }
            return .number(integer: type == .integer, min: min, max: max, exclusiveMin: exclusiveMin, exclusiveMax: exclusiveMax)
        case .boolean: return .boolean
        }
    }
}

public enum SMLModelOutputContractError: Error, Sendable, CustomStringConvertible {
    case invalidSchema(path: String, reason: String)
    case mismatch(path: String, reason: String)

    public var description: String {
        switch self {
        case .invalidSchema(let path, let reason): return "invalid SML model schema at \(path): \(reason)"
        case .mismatch(let path, let reason): return "SML model output contract failed at \(path): \(reason)"
        }
    }
}
