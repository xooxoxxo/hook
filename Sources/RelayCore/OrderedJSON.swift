import Foundation

/// A JSON document that keeps object keys in file order and strings, numbers and literals
/// exactly as written, so a rewrite changes only what it means to (the replies hook merge
/// into a settings file someone else keeps). Parse only text `JSONSerialization` accepted:
/// the parser checks structure, not every token.
enum OrderedJSON {
    /// One object member; `key` is its raw string token, quotes and escapes included.
    struct Member {
        var key: String
        var value: OrderedJSON
    }

    /// Members in file order.
    case object([Member])
    case array([OrderedJSON])
    /// A string token (quoted, escapes as written), a number or true/false/null.
    case scalar(String)

    struct ParseError: Error {}

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
        let value = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw ParseError() }
        return value
    }

    /// A string as a JSON string token, slashes left unescaped.
    static func string(_ text: String) -> OrderedJSON {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            ?? Data("\"\"".utf8)
        return .scalar(String(decoding: data, as: UTF8.self))
    }

    /// The decoded text of a raw key token, for comparing keys.
    static func keyText(_ raw: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) as? String
    }

    /// The member named `key`, if this is an object that has one.
    func member(_ key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { Self.keyText($0.key) == key }?.value
    }

    /// Sets the member named `key`, in place when it exists, else at the end.
    mutating func setMember(_ key: String, _ value: OrderedJSON) {
        guard case .object(var members) = self else { return }
        if let index = members.firstIndex(where: { Self.keyText($0.key) == key }) {
            members[index].value = value
        } else if case .scalar(let raw) = Self.string(key) {
            members.append(Member(key: raw, value: value))
        }
        self = .object(members)
    }

    /// Pretty-printed with two spaces, `"key": value`, empty containers as {} and [].
    func text(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent + 1), end = String(repeating: "  ", count: indent)
        switch self {
        case .scalar(let raw):
            return raw
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { pad + $0.text(indent: indent + 1) }.joined(separator: ",\n") + "\n" + end + "]"
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            return "{\n" + members.map { pad + $0.key + ": " + $0.value.text(indent: indent + 1) }
                .joined(separator: ",\n") + "\n" + end + "}"
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ byte: UInt8) throws {
            skipSpace()
            guard index < bytes.count, bytes[index] == byte else { throw ParseError() }
            index += 1
        }

        /// True, and past it, when the next byte is `byte`.
        mutating func take(_ byte: UInt8) -> Bool {
            skipSpace()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func value() throws -> OrderedJSON {
            skipSpace()
            guard index < bytes.count else { throw ParseError() }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [Member] = []
                if take(UInt8(ascii: "}")) { return .object([]) }
                repeat {
                    skipSpace()
                    let key = try string()
                    try expect(UInt8(ascii: ":"))
                    members.append(Member(key: key, value: try value()))
                } while take(UInt8(ascii: ","))
                try expect(UInt8(ascii: "}"))
                return .object(members)
            case UInt8(ascii: "["):
                index += 1
                var items: [OrderedJSON] = []
                if take(UInt8(ascii: "]")) { return .array([]) }
                repeat { items.append(try value()) } while take(UInt8(ascii: ","))
                try expect(UInt8(ascii: "]"))
                return .array(items)
            case UInt8(ascii: "\""):
                return .scalar(try string())
            default:
                let start = index
                while index < bytes.count, !Array(",]} \n\r\t".utf8).contains(bytes[index]) { index += 1 }
                guard index > start else { throw ParseError() }
                return .scalar(String(decoding: bytes[start..<index], as: UTF8.self))
            }
        }

        /// The raw string token at `index`, quotes included.
        mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError() }
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { throw ParseError() }
            index += 1
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}
