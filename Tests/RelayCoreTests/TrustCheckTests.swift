import Foundation
import Testing
@testable import RelayCore

private func makeFolder(mode: mode_t) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "relay-trust-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    #expect(chmod(url.path, mode) == 0)
    return url
}

@Suite struct TrustCheckTests {
    @Test func worldWritableFolderIsRefused() throws {
        let dir = try makeFolder(mode: 0o777)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try PrivateFile.checkTrusted(directory: dir)
            Issue.record("expected a throw")
        } catch let error as PrivateFile.TrustError {
            guard case .untrustedDirectory(let message) = error else { Issue.record("wrong case"); return }
            #expect(message.contains("writable by other users"))
        }
    }

    @Test func groupWritableFolderIsRefusedAndPlainReadableIsTrusted() throws {
        let group = try makeFolder(mode: 0o775)
        let plain = try makeFolder(mode: 0o755)
        defer {
            try? FileManager.default.removeItem(at: group)
            try? FileManager.default.removeItem(at: plain)
        }
        #expect(throws: PrivateFile.TrustError.self) { try PrivateFile.checkTrusted(directory: group) }
        try PrivateFile.checkTrusted(directory: plain)
    }

    @Test func folderOwnedByAnotherUserIsRefused() {
        do {
            try PrivateFile.checkTrusted(directory: URL(fileURLWithPath: "/"))
            Issue.record("expected a throw")
        } catch let error as PrivateFile.TrustError {
            #expect(error.localizedDescription.contains("belongs to another user"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func queueInAFolderOwnedByAnotherUserGetsTheTrustMessage() async {
        let queue = LocalQueue(directory: URL(fileURLWithPath: "/"), keepDays: 14)
        do {
            _ = try await queue.open()
            Issue.record("expected a throw")
        } catch LocalQueueError.storeFailed(let message) {
            #expect(message.contains("belongs to another user"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func symlinkToOwnFileIsAcceptedAndDirectoryIsRefused() throws {
        let dir = try makeFolder(mode: 0o700)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appending(path: "real.json")
        try Data("{}".utf8).write(to: real)
        let link = dir.appending(path: "link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try PrivateFile.checkTrusted(file: link)
        try PrivateFile.checkTrusted(file: dir.appending(path: "missing.json"))
        let folder = dir.appending(path: "folder.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(throws: PrivateFile.TrustError.self) { try PrivateFile.checkTrusted(file: folder) }
    }

    @Test func writeRefusesAnUntrustedFolderAndCreatesNothing() throws {
        let dir = try makeFolder(mode: 0o777)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        #expect(throws: PrivateFile.TrustError.self) { try PrivateFile.write(Data("x".utf8), to: file) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func configLoadReportsAnUntrustedFolder() throws {
        let dir = try makeFolder(mode: 0o777)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        try Data("{}".utf8).write(to: file)
        guard case .unreadable(let message) = ConfigStore.load(file) else {
            Issue.record("expected unreadable"); return
        }
        #expect(message.contains("writable by other users"))
    }

    @Test func configLoadReportsADirectoryInPlaceOfTheFile() throws {
        let dir = try makeFolder(mode: 0o700)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        guard case .unreadable(let message) = ConfigStore.load(file) else {
            Issue.record("expected unreadable"); return
        }
        #expect(message.contains("not a regular file owned by you"))
    }

    @Test func localTokenRefusesAnUntrustedFolder() throws {
        let dir = try makeFolder(mode: 0o777)
        defer { try? FileManager.default.removeItem(at: dir) }
        let token = LocalToken(file: dir.appending(path: "local-token"))
        #expect(throws: PrivateFile.TrustError.self) { _ = try token.ensure() }
        #expect(!FileManager.default.fileExists(atPath: token.file.path))
        try Data("planted\n".utf8).write(to: token.file)
        #expect(token.read() == nil)
        #expect(throws: PrivateFile.TrustError.self) { _ = try token.ensure() }
    }

    @Test func queueOpenRefusesAQueueFileThatIsNotYours() async throws {
        let dir = try makeFolder(mode: 0o700)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appending(path: "queue.json"), withIntermediateDirectories: false)
        let queue = LocalQueue(directory: dir, keepDays: 14)
        do {
            _ = try await queue.open()
            Issue.record("expected a throw")
        } catch let error as LocalQueueError {
            guard case .storeFailed(let message) = error else { Issue.record("wrong case"); return }
            #expect(message.contains("not a regular file owned by you"))
        }
    }
}
