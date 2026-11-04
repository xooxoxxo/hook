import CryptoKit
import Foundation
import Testing
@testable import RelayCore

/// 0.14: no Keychain call on the main thread (0.13.1 froze at launch behind a Keychain prompt).
@Suite struct KeychainQueueTests {
    @Test @MainActor func aCallFromTheMainActorRunsOffTheMainThread() async {
        #expect(await KeychainQueue.shared.run { pthread_main_np() == 0 })
    }

    @Test func anErrorComesBackToTheCaller() async {
        await #expect(throws: SecretStoreError.unreadable(-128)) {
            try await KeychainQueue.shared.run { () throws -> Int in throw SecretStoreError.unreadable(-128) }
        }
    }

    /// A read held by a prompt nobody answers blocks only the Keychain queue: the main actor
    /// keeps running, and the read finishes once the prompt is answered.
    @Test @MainActor func aHeldReadLeavesTheMainActorFree() async throws {
        let secrets = MemorySecretStore([.reviewSeal: Data([1])])
        secrets.holdReads()
        let keychain = KeychainQueue(label: "test.held")
        let read = Task { try await keychain.run { try secrets.read(.reviewSeal) } }
        while secrets.waitingReads == 0 { await Task.yield() }
        var ran = false
        await MainActor.run { ran = true }
        #expect(ran)
        secrets.releaseReads()
        #expect(try await read.value == Data([1]))
    }
}

@Suite struct KeychainWaitStateTests {
    private let two = RevisionStamp(rev: 2, hash: "h2")

    @Test func waitingIsLockedWithNoReviewToOffer() {
        let state = ReviewState.waitingForKeychain(current: two)
        #expect(state.isLocked)
        #expect(state.action == nil)
    }

    @Test func theLockBarSaysWhatItWaitsFor() throws {
        let bar = try #require(ReviewLockBar.make(.waitingForKeychain(current: two)))
        #expect(bar.tone == .keychain)
        #expect(bar.title == "Waiting for Keychain access")
        #expect(bar.detail == "Allow Hook when macOS asks for your password. Until then this correction stays locked.")
        #expect(bar.action == nil)
    }

    @Test func theRowSaysItToo() {
        let row = AskRowModel(id: "a", title: "A", project: "p", urgency: .today, created: "",
                              summary: .steps(done: 0, total: 1), review: .waitingForKeychain(current: two))
        #expect(row.waitingForKeychain)
        #expect(!row.corrected)
        #expect(!row.historyChanged)
    }

    /// Rendered like a correction nobody has seen here: rev 1, locked.
    @Test func itRendersRevisionOne() {
        let one = RevisionStamp(rev: 1, hash: "h1")
        let body = Instructable(v: 1, title: "T", steps: [])
        let history = VerifiedHistory(bodies: [1: body, 2: body], stamps: [1: one, 2: two], current: two,
                                      acceptedOnPond: 2, reasons: [:])
        #expect(ReviewGate.renderedStamp(.waitingForKeychain(current: two), history: history) == one)
    }
}
