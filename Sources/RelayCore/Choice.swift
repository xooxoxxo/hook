import Foundation

/// One choice of a question or the reply. A plain string is a choice without words; Pond 1.4.0
/// adds an object, `{"label": "Mix", "text": "What should change?"}`, whose `text` is the
/// placeholder of the field the owner writes words in. The validator holds the limits; decoding
/// only needs the shape.
public struct Choice: Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public var label: String
    /// The words field's placeholder; nil for a plain choice.
    public var text: String?

    public init(_ label: String, text: String? = nil) {
        self.label = label; self.text = text
    }

    public init(stringLiteral value: String) { self.init(value) }

    /// Takes words from the owner.
    public var hasWords: Bool { text != nil }

    enum CodingKeys: String, CodingKey {
        case label, text
    }

    /// A string, or an object with a string `label` (a `text` that isn't a string reads as none).
    /// Anything else throws, so the question holding it decodes as nil.
    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let label = try? single.decode(String.self) {
            self.init(label)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(String.self, forKey: .label),
                  text: (try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil)
    }

    /// A plain choice encodes back as its string, so a plain instructable reads as before.
    public func encode(to encoder: any Encoder) throws {
        guard let text else {
            var single = encoder.singleValueContainer()
            try single.encode(label)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(text, forKey: .text)
    }

    /// How a correction shows the choice: "Mix (What should change?)", or the label alone.
    public var diffText: String { text.map { "\(label) (\($0))" } ?? label }
}

extension [Choice] {
    /// The labels, in order.
    public var labels: [String] { map(\.label) }
}
