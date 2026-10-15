import Foundation
import Testing
@testable import RelayCore

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "relay-tests-\(UUID().uuidString)")
}

private func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}

@Suite struct PrivateFileTests {
    @Test func writeCreatesA0600FileInA0700Directory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "a/b/private.json")

        try PrivateFile.write(Data("one".utf8), to: url)

        #expect(try Data(contentsOf: url) == Data("one".utf8))
        #expect(try mode(url) == 0o600)
        #expect(try mode(url.deletingLastPathComponent()) == 0o700)
    }

    @Test func rewriteReplacesTheContentsAndLeavesNoTempFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "private.json")

        try PrivateFile.write(Data("one".utf8), to: url)
        try PrivateFile.write(Data("two".utf8), to: url)
        try PrivateFile.write(Data(), to: url.deletingLastPathComponent().appending(path: "empty.json"))

        #expect(try Data(contentsOf: url) == Data("two".utf8))
        #expect(try mode(url) == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(names == ["empty.json", "private.json"])
    }

    @Test func ensureDirectoryTightensAnExistingDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o755) == 0)
        #expect(try mode(root) == 0o755)

        try PrivateFile.ensureDirectory(root)

        #expect(try mode(root) == 0o700)
    }

    @Test func writeLeavesAnExistingParentsModeAlone() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o755) == 0)

        try PrivateFile.write(Data("one".utf8), to: root.appending(path: "private.json"))

        #expect(try mode(root) == 0o755)
        #expect(try mode(root.appending(path: "private.json")) == 0o600)
    }

    @Test func onlyTheDefaultConfigDirectoryIsTightened() {
        let data = URL(fileURLWithPath: "/tmp/relay-example/data")
        let defaultConfig = RelayConfig.path(environment: [:])
        let owned = RelayConfig.ownedDirectories(configURL: defaultConfig, dataDirectory: data)
        #expect(owned.tighten == [defaultConfig.deletingLastPathComponent(), data])
        #expect(owned.createOnly.isEmpty)

        let custom = URL(fileURLWithPath: "/tmp/relay-example/shared/relay.json")
        let other = RelayConfig.ownedDirectories(configURL: custom, dataDirectory: data)
        #expect(other.tighten == [data])
        #expect(other.createOnly == [custom.deletingLastPathComponent()])
    }

    @Test func writeFailsWhenTheParentIsAFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appending(path: "plain-file")
        try PrivateFile.write(Data("x".utf8), to: parent)

        #expect(throws: (any Error).self) {
            try PrivateFile.write(Data("y".utf8), to: parent.appending(path: "child.json"))
        }
        #expect(try Data(contentsOf: parent) == Data("x".utf8))
    }
}
