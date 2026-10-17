import Testing
@testable import RelayCore

@Suite struct StepFingerprintTests {
    @Test func knownAnswers() {
        #expect(StepFingerprint.make(kind: .step, action: "Open Slack", place: "Slack", code: nil) == "6d92f6ea9ee54330")
        #expect(StepFingerprint.make(kind: .verify, action: "Check it", place: nil, code: "ls") == "6091cad6d8c1097f")
        #expect(StepFingerprint.make(kind: .sub, action: "Name it", place: nil, code: nil) == "f9c4d007889a19b9")
    }

    @Test func sixteenLowercaseHex() {
        let value = StepFingerprint.make(kind: .step, action: "x", place: nil, code: nil)
        #expect(value.count == 16)
        #expect(value.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func theParentIsPartOfASubStep() {
        let p1 = StepFingerprint.make(kind: .step, action: "Create the app", place: "api.example.com", code: nil)
        let p2 = StepFingerprint.make(kind: .step, action: "Create the bot", place: "api.example.com", code: nil)
        #expect(p1 == "3c8ff85fe3aeded9")
        #expect(p2 == "81b8074fe694e324")
        #expect(StepFingerprint.make(kind: .sub, action: "Name it", place: nil, code: nil, parent: p1) == "56ad546aa7633e75")
        #expect(StepFingerprint.make(kind: .sub, action: "Name it", place: nil, code: nil, parent: p2) == "8b38f8596373cdd0")
    }

    @Test func kindAndEveryFieldCount() {
        let base = StepFingerprint.make(kind: .step, action: "a", place: "b", code: "c")
        #expect(base != StepFingerprint.make(kind: .verify, action: "a", place: "b", code: "c"))
        #expect(base != StepFingerprint.make(kind: .step, action: "a", place: nil, code: "c"))
        #expect(base != StepFingerprint.make(kind: .step, action: "a", place: "b", code: nil))
        #expect(StepFingerprint.make(kind: .step, action: "a", place: nil, code: nil)
            == StepFingerprint.make(kind: .step, action: "a", place: "", code: ""))
    }
}
