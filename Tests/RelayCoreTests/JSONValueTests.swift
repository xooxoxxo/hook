import Foundation
import Testing
@testable import RelayCore

private func parse(_ text: String) throws -> JSONValue {
    try JSONValue.parse(Data(text.utf8))
}

@Suite struct JSONValueTests {
    @Test func numbersAndBooleansKeepTheirKind() throws {
        #expect(try parse("1") == .int(1))
        #expect(try parse("-3") == .int(-3))
        #expect(try parse("1.0") == .double(1.0))
        #expect(try parse("1e0") == .double(1.0))
        #expect(try parse("true") == .bool(true))
        #expect(try parse("false") == .bool(false))
        #expect(try parse("null") == .null)
        #expect(try parse(#""x""#) == .string("x"))
    }

    @Test func aHugeNumberBecomesADouble() throws {
        guard case .double = try parse("12345678901234567890") else {
            Issue.record("expected .double")
            return
        }
    }

    @Test func aNestedDocument() throws {
        let value = try parse(#"{"a":[1,"b",null],"c":{"d":false}}"#)
        #expect(value == .object([
            "a": .array([.int(1), .string("b"), .null]),
            "c": .object(["d": .bool(false)]),
        ]))
        #expect(value["c"] == .object(["d": .bool(false)]))
        #expect(value["missing"] == nil)
        #expect(value["a"]?.stringValue == nil)
        #expect(JSONValue.string("x").stringValue == "x")
        #expect(JSONValue.string("x")["a"] == nil)
    }

    @Test(arguments: [#""\ud800""#, #"{"t":"\ud800"}"#, #"{"t":"a\udc00b"}"#, "{", ""])
    func invalidJSONThrows(_ body: String) {
        #expect(throws: JSONValueError.invalidJSON) {
            try JSONValue.parse(Data(body.utf8))
        }
    }

    @Test func dataIsCompactWithSortedKeysAndPlainSlashes() {
        let value: JSONValue = .object(["b": .int(1), "a": .string("x/y"), "c": .array([.bool(true), .null])])
        #expect(String(decoding: value.data(), as: UTF8.self) == #"{"a":"x/y","b":1,"c":[true,null]}"#)
        #expect(String(decoding: JSONValue.string("é").data(), as: UTF8.self) == #""é""#)
    }

    @Test func foundationRoundTrip() throws {
        let value: JSONValue = .object([
            "v": .int(1), "ok": .bool(true), "x": .null, "s": .string("a/b"),
            "list": .array([.double(1.5), .int(-2)]),
        ])
        #expect(try JSONValue(foundation: value.foundation) == value)
        #expect(try JSONValue.parse(value.data()) == value)
    }

    @Test func codableRoundTrip() throws {
        let value: JSONValue = .object([
            "v": .int(1), "ok": .bool(false), "x": .null, "s": .string("a"),
            "list": .array([.double(1.5), .int(-2), .object([:])]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test func pySizeMatchesFixedPythonCounts() {
        #expect(PySize.bytes(.object([:])) == 2)                                     // {}
        #expect(PySize.bytes(.array([])) == 2)                                       // []
        #expect(PySize.bytes(.array([.int(1), .bool(true), .null])) == 15)           // [1, true, null]
        #expect(PySize.bytes(.object(["a": .string("é\n\"")])) == 15)                // {"a": "é\n\""}
        #expect(PySize.bytes(.object(["k": .int(-12), "l": .string("/")])) == 20)    // {"k": -12, "l": "/"}
        #expect(PySize.bytes(.string("\u{1}")) == 8)                                 // "\u0001"
        #expect(PySize.bytes(.string("\u{7F}\u{2028}")) == 6)                        // DEL raw (1) + U+2028 raw (3)
        #expect(PySize.bytes(.double(1.5)) == 3)
        #expect(PySize.bytes(.bool(false)) == 5)
    }
}
