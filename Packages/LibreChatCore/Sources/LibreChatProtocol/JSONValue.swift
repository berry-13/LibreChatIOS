import Foundation

public enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case let .number(value) = self else { return nil }
        // A valid JSON number can sit far outside platform Int bounds
        // (e.g. 1e100); Int(value) would trap instead of returning nil.
        // Double(Int.max) rounds UP to 2^63, so the inclusive upper bound
        // would admit values that trap Int(value). Use the strictly smaller
        // power of two as an overflow-safe bound.
        guard value.isFinite,
              value >= Double(Int.min),
              value < 9_223_372_036_854_775_808.0 else {
            return nil
        }
        return Int(value)
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public func textValue() -> String? {
        switch self {
        case let .string(value):
            value
        case let .array(values):
            values.compactMap { $0.textValue() }.joined()
        case let .object(object):
            object["text"]?.textValue()
                ?? object["value"]?.textValue()
                ?? object["content"]?.textValue()
        default:
            nil
        }
    }
}
