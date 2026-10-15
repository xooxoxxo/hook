import Foundation

/// The UTF-8 byte length of Python's `json.dumps(value, ensure_ascii=False)`:
/// separators ", " and ": ", non-ASCII raw, "/" unescaped, `"` and `\` escaped,
/// \n \r \t \b \f as two characters, other control characters as \uXXXX.
/// Floats use Swift's `description`, which can differ from Python's repr by a
/// few bytes (e.g. 1e15); integers and everything else match exactly.
public enum PySize {
    public static func bytes(_ value: JSONValue) -> Int {
        switch value {
        case .null:
            return 4
        case .bool(let flag):
            return flag ? 4 : 5
        case .int(let number):
            return String(number).utf8.count
        case .double(let number):
            return number.description.utf8.count
        case .string(let text):
            return stringBytes(text)
        case .array(let items):
            guard !items.isEmpty else { return 2 }
            return 2 + items.reduce(0) { $0 + bytes($1) } + 2 * (items.count - 1)
        case .object(let members):
            guard !members.isEmpty else { return 2 }
            let inner = members.reduce(0) { $0 + stringBytes($1.key) + 2 + bytes($1.value) }
            return 2 + inner + 2 * (members.count - 1)
        }
    }

    static func stringBytes(_ text: String) -> Int {
        var total = 2
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D:
                total += 2
            case 0x00..<0x20:
                total += 6
            default:
                total += UTF8.width(scalar)
            }
        }
        return total
    }
}
