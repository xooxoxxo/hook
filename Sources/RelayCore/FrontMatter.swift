import Foundation

/// A Markdown document's front matter: the YAML between an opening `---` on the first line and
/// the next `---` (or `...`) line. The viewer reads it off the body and shows it as a quiet
/// strip above the document (spec "Viewer: front matter"); it is never body text.
///
/// The reader takes the flat subset notes use: `key: value`, quoted values, `[a, b]` lists,
/// indented `- item` lists, `|` and `>` blocks, comments and blank lines. A nested map is kept
/// as its indented text. Anything else (a line that isn't `key:`, an unclosed list or quote)
/// makes the whole block `malformed`: shown raw, collapsed, and still kept out of the body.
public enum FrontMatter: Equatable, Sendable {
    /// No opening fence on the first line, or no closing one.
    case absent
    case fields([Field])
    /// The text between the fences, as written (line ends normalised to "\n").
    case malformed(String)

    public struct Field: Equatable, Sendable {
        public var key: String
        public var value: Value

        public init(key: String, value: Value) {
            self.key = key
            self.value = value
        }
    }

    public enum Value: Equatable, Sendable {
        case text(String)
        case list([String])

        /// The value on one line: a list's items joined with ", ".
        public var display: String {
            switch self {
            case .text(let text): return text
            case .list(let items): return items.joined(separator: ", ")
            }
        }
    }

    /// The front matter and the rest of the document. Absent, `body` is `text` unchanged.
    public static func split(_ text: String) -> (front: FrontMatter, body: String) {
        var rest = Substring(text)
        if rest.hasPrefix("\u{FEFF}") { rest = rest.dropFirst() }
        guard let opening = nextLine(&rest), fence(opening) == "---" else { return (.absent, text) }
        var inner: [String] = []
        while let line = nextLine(&rest) {
            let mark = fence(line)
            if mark == "---" || mark == "..." {
                let block = inner.joined(separator: "\n")
                return (parse(inner).map(FrontMatter.fields) ?? .malformed(block), String(rest))
            }
            inner.append(String(line.hasSuffix("\r") ? line.dropLast() : line))
        }
        return (.absent, text)
    }

    /// Takes the next line off `rest` (without its "\n" or "\r\n"); nil at the end.
    private static func nextLine(_ rest: inout Substring) -> Substring? {
        guard !rest.isEmpty else { return nil }
        // "\r\n" is one Character in Swift.
        if let end = rest.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rest[..<end]
            rest = rest[rest.index(after: end)...]
            return line
        }
        let line = rest
        rest = rest[rest.endIndex...]
        return line
    }

    /// A line without its trailing spaces and "\r", to compare with a fence.
    private static func fence(_ line: Substring) -> Substring {
        var end = line.endIndex
        while end > line.startIndex, " \t\r".contains(line[line.index(before: end)]) { end = line.index(before: end) }
        return line[..<end]
    }

    private static func isIndented(_ line: String) -> Bool { line.first == " " || line.first == "\t" }
    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }
    private static func trimmed(_ text: some StringProtocol) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    /// The fields, or nil when a line isn't in the subset.
    static func parse(_ lines: [String]) -> [Field]? {
        var fields: [Field] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            if isBlank(line) || line.hasPrefix("#") { continue }
            guard !isIndented(line), let colon = keyColon(line) else { return nil }
            let key = trimmed(line[..<colon])
            let rest = trimmed(line[line.index(after: colon)...])
            // The indented lines under the key (blank ones inside them too).
            var nested: [String] = []
            while i < lines.count, isIndented(lines[i]) || (isBlank(lines[i]) && !nested.isEmpty) {
                nested.append(lines[i])
                i += 1
            }
            while let last = nested.last, isBlank(last) { nested.removeLast() }
            let value: Value
            if rest.isEmpty || rest.hasPrefix("#") {
                value = nestedValue(nested)
            } else {
                guard nested.isEmpty || rest.hasPrefix("|") || rest.hasPrefix(">"),
                      let read = scalarValue(rest, block: nested) else { return nil }
                value = read
            }
            fields.append(Field(key: key, value: value))
        }
        return fields
    }

    /// The colon that ends a key: the first ": " (or a final ":") after a plain key.
    private static func keyColon(_ line: String) -> String.Index? {
        guard let first = line.first, first.isLetter || first.isNumber || first == "_" else { return nil }
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == ":" {
                let next = line.index(after: index)
                if next == line.endIndex || line[next] == " " || line[next] == "\t" { return index }
            } else if !(character.isLetter || character.isNumber || "_-. /".contains(character)) {
                return nil
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// The lines under an empty value: a `- item` list, else their text, dedented.
    private static func nestedValue(_ nested: [String]) -> Value {
        let lines = nested.map(trimmed)
        let items = lines.filter { !$0.isEmpty }
        if !items.isEmpty, items.allSatisfy({ $0 == "-" || $0.hasPrefix("- ") }) {
            return .list(items.map { unquote(trimmed($0.dropFirst())) ?? trimmed($0.dropFirst()) })
        }
        return .text(lines.joined(separator: "\n"))
    }

    /// A value on the key's own line; nil when it doesn't close.
    private static func scalarValue(_ rest: String, block: [String]) -> Value? {
        if rest.hasPrefix("|") || rest.hasPrefix(">") {
            let lines = block.map(trimmed)
            return .text(lines.joined(separator: rest.hasPrefix("|") ? "\n" : " "))
        }
        if rest.hasPrefix("[") {
            guard rest.hasSuffix("]") else { return nil }
            var items: [String] = []
            for part in splitList(String(rest.dropFirst().dropLast())) {
                let item = trimmed(part)
                guard !item.isEmpty else { continue }
                guard let plain = unquote(item) else { return nil }
                items.append(plain)
            }
            return .list(items)
        }
        if rest.hasPrefix("{") { return rest.hasSuffix("}") ? .text(rest) : nil }
        if rest.hasPrefix("\"") || rest.hasPrefix("'") { return unquote(rest).map(Value.text) }
        // A plain value; " #" starts a comment.
        if let comment = rest.range(of: " #") { return .text(trimmed(rest[..<comment.lowerBound])) }
        return .text(rest)
    }

    /// The items of a flow list, split at commas outside quotes and brackets.
    private static func splitList(_ text: String) -> [String] {
        var parts: [String] = [], current = "", quote: Character?, depth = 0
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth -= 1
            } else if character == ",", depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)
        return parts
    }

    /// A quoted value's text; a plain one as it is; nil for a quote that doesn't close.
    private static func unquote(_ text: String) -> String? {
        guard let open = text.first, open == "\"" || open == "'" else { return text }
        guard text.count >= 2, text.last == open else { return nil }
        let inner = String(text.dropFirst().dropLast())
        return open == "'" ? inner.replacingOccurrences(of: "''", with: "'")
            : inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// What the viewer's strip shows: `tags` as chips, `created` and `status` inline, the other
    /// keys behind "N more". Nil when there is nothing to show (absent, malformed or empty).
    public struct Strip: Equatable, Sendable {
        public var tags: [String]
        public var inline: [Field]
        public var more: [Field]

        /// The keys shown on the line itself, in this order.
        public static let inlineKeys = ["created", "status"]
        public static let tagKeys: Set<String> = ["tags", "tag"]

        public var moreTitle: String { "\(more.count) more" }

        public init?(_ front: FrontMatter) {
            guard case .fields(let fields) = front, !fields.isEmpty else { return nil }
            var tags: [String] = [], inline: [Field] = [], more: [Field] = []
            for field in fields {
                let key = field.key.lowercased()
                if Self.tagKeys.contains(key) {
                    tags += Self.tagList(field.value)
                } else if !Self.inlineKeys.contains(key) {
                    more.append(field)
                }
            }
            for key in Self.inlineKeys {
                if let field = fields.last(where: { $0.key.lowercased() == key }), !field.value.display.isEmpty {
                    inline.append(field)
                }
            }
            guard !(tags.isEmpty && inline.isEmpty && more.isEmpty) else { return nil }
            self.tags = tags
            self.inline = inline
            self.more = more
        }

        /// A tag list, or a text of tags split at commas and spaces; a leading "#" dropped.
        static func tagList(_ value: Value) -> [String] {
            let raw: [String]
            switch value {
            case .list(let items): raw = items
            case .text(let text): raw = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            }
            return raw.map { trimmed($0) }.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
                .filter { !$0.isEmpty }
        }
    }
}
