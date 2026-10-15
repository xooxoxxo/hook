import Foundation

public enum JSONValueError: Error, Sendable, Equatable {
    case invalidJSON
}

/// A JSON document as a typed value, so integers, floats and booleans stay
/// apart (`v` must be the integer 1, not `1.0` or `true`).
public enum JSONValue: Sendable, Equatable, Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    /// Parses with `JSONSerialization`, which rejects a lone-surrogate escape
    /// such as `"\ud800"`. Any failure is `JSONValueError.invalidJSON`.
    public static func parse(_ data: Data) throws -> JSONValue {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONValueError.invalidJSON
        }
        return try JSONValue(foundation: object)
    }

    /// Converts what `JSONSerialization` returns. A bool is a `CFBoolean`; an
    /// integer is an `NSNumber` whose objCType isn't "d" or "f"; an
    /// `NSDecimalNumber` (a huge number) becomes a double.
    public init(foundation value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            self = Self.number(number)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(try array.map { try JSONValue(foundation: $0) })
        case let dictionary as [String: Any]:
            var members: [String: JSONValue] = [:]
            for (key, inner) in dictionary {
                members[key] = try JSONValue(foundation: inner)
            }
            self = .object(members)
        default:
            throw JSONValueError.invalidJSON
        }
    }

    private static func number(_ number: NSNumber) -> JSONValue {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        if number is NSDecimalNumber { return .double(number.doubleValue) }
        let type = String(cString: number.objCType)
        if type == "d" || type == "f" { return .double(number.doubleValue) }
        if type == "Q", number.uint64Value > UInt64(Int.max) { return .double(number.doubleValue) }
        return .int(number.intValue)
    }

    /// Back to values `JSONSerialization` can write. A non-finite double,
    /// which JSON can't hold, becomes null.
    public var foundation: Any {
        switch self {
        case .object(let members): return members.mapValues { $0.foundation }
        case .array(let items): return items.map { $0.foundation }
        case .string(let text): return text
        case .int(let number): return NSNumber(value: number)
        case .double(let number): return number.isFinite ? NSNumber(value: number) : NSNull()
        case .bool(let flag): return NSNumber(value: flag)
        case .null: return NSNull()
        }
    }

    /// Compact JSON with sorted keys and unescaped slashes.
    public func data() -> Data {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        return (try? JSONSerialization.data(withJSONObject: foundation, options: options)) ?? Data("null".utf8)
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    public var stringValue: String? {
        guard case .string(let text) = self else { return nil }
        return text
    }

    // Codable, for storing a cleaned instructable inside queue.json. A double
    // with no fraction (1.0) can come back as .int(1); validated documents
    // only hold the integer `v`, so nothing depends on that difference.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let members): try container.encode(members)
        case .array(let items): try container.encode(items)
        case .string(let text): try container.encode(text)
        case .int(let number): try container.encode(number)
        case .double(let number): try container.encode(number)
        case .bool(let flag): try container.encode(flag)
        case .null: try container.encodeNil()
        }
    }
}
