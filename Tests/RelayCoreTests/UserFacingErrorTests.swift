import Foundation
import Testing
@testable import RelayCore

private struct Plain: Error {}

@Suite struct UserFacingErrorTests {
    @Test func localizedErrorsUseTheirDescription() {
        #expect(UserFacingError.text(QueueError.unreachable("The mailbox didn't answer within 10 seconds."))
            == "The mailbox didn't answer within 10 seconds.")
        #expect(UserFacingError.text(QueueError.unauthorized) == "The mailbox rejected the token (check the token file)")
    }

    @Test func newlinesAndBidiAreRevealedOnOneLine() {
        #expect(UserFacingError.text(QueueError.unreachable("line one\nline two")) == "line one⟨U+000A⟩line two")
        #expect(UserFacingError.text("evil\u{202E}txt") == "evil⟨U+202E⟩txt")
        #expect(UserFacingError.text("  trailing\n") == "trailing")
        #expect(UserFacingError.text(" ") == "Unknown error")
    }

    @Test func otherErrors() {
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                         userInfo: [NSLocalizedDescriptionKey: "The request timed out."])
        #expect(UserFacingError.text(ns) == "The request timed out.")
        #expect(UserFacingError.text(Plain()) == "Plain()")
    }
}
