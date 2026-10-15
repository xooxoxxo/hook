import CryptoKit
import Foundation
import Testing
@testable import RelayCore

@Suite struct LocalTokenTests {
    private func tokenFile() -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "relay-token-\(UUID().uuidString)")
        return (dir, dir.appending(path: "local-token"))
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func isLowerHex(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    @Test func ensureCreatesAPrivateHexTokenOnce() throws {
        let (dir, file) = tokenFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let token = LocalToken(file: file)
        #expect(token.read() == nil)

        let created = try token.ensure()
        #expect(created.count == 64)
        #expect(isLowerHex(created))
        #expect(try mode(file) == 0o600)
        #expect(try mode(dir) == 0o700)
        #expect(try Data(contentsOf: file) == Data(created.utf8))
        #expect(token.read() == created)

        #expect(try token.ensure() == created)
        #expect(try LocalToken(file: file).ensure() == created)
    }

    @Test func emptyFileGetsANewToken() throws {
        let (dir, file) = tokenFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        try PrivateFile.write(Data(" \n".utf8), to: file)
        let token = LocalToken(file: file)
        #expect(token.read() == nil)
        let created = try token.ensure()
        #expect(created.count == 64)
        #expect(token.read() == created)
    }

    @Test func wideModeIsTightened() throws {
        let (dir, file) = tokenFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = String(repeating: "ab", count: 32)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((existing + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        #expect(try LocalToken(file: file).ensure() == existing)
        #expect(try mode(file) == 0o600)
    }

    @Test func proofMatchesHMACVector() {
        let token = String(repeating: "ab", count: 32)
        let nonce = "0123456789abcdef0123456789abcdef"
        let expected = HMAC<SHA256>.authenticationCode(
            for: Data("relay-proof-v1\n47823\n\(nonce)".utf8), using: SymmetricKey(data: Data(token.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        #expect(LocalToken.proof(token: token, port: 47823, nonce: nonce) == expected)
        // The same vectors from Python: hmac.new(token, b"relay-proof-v1\n47823\n" + nonce, sha256).hexdigest()
        #expect(LocalToken.proof(token: token, port: 47823, nonce: nonce)
                == "5b008b5ba39aee57aa562663270a99e856596c1a3c520a3142555cfbd54bd5c5")
        #expect(LocalToken.proof(token: token, port: 47900, nonce: nonce)
                == "d71c974915457e5711657d21de233e2558a6890840add986031e81f2b8fa6f25")
        #expect(LocalToken.proof(token: token, port: 47823, nonce: nonce.uppercased()) != expected)
    }

    @Test func concurrentEnsureOnAMissingFileAgreesOnOneToken() async throws {
        for _ in 0..<20 {
            let (dir, file) = tokenFile()
            defer { try? FileManager.default.removeItem(at: dir) }
            let tokens = await withTaskGroup(of: String?.self) { group in
                for _ in 0..<8 {
                    group.addTask { try? LocalToken(file: file).ensure() }
                }
                var all: [String?] = []
                for await token in group { all.append(token) }
                return all
            }
            let onDisk = try #require(LocalToken(file: file).read())
            #expect(tokens.allSatisfy { $0 == onDisk })
        }
    }

    @Test func tokenWriteLeavesAnExistingCustomParentAlone() throws {
        let (dir, file) = tokenFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(chmod(dir.path, 0o755) == 0)

        _ = try LocalToken(file: file).ensure()

        #expect(try mode(dir) & 0o777 == 0o755)
        #expect(try mode(file) & 0o777 == 0o600)
    }

    @Test func nonceValidation() {
        #expect(LocalToken.isValidNonce(String(repeating: "a", count: 32)))
        #expect(LocalToken.isValidNonce(String(repeating: "F", count: 64)))
        #expect(LocalToken.isValidNonce("0123456789abcdefABCDEF0123456789"))
        #expect(!LocalToken.isValidNonce(String(repeating: "a", count: 31)))
        #expect(!LocalToken.isValidNonce(String(repeating: "a", count: 65)))
        #expect(!LocalToken.isValidNonce(String(repeating: "g", count: 32)))
        #expect(!LocalToken.isValidNonce(String(repeating: "a", count: 31) + "é"))
        #expect(!LocalToken.isValidNonce(""))
    }

    @Test func matchesComparesWholeValues() {
        let token = String(repeating: "ab", count: 32)
        #expect(LocalToken.matches(token, token))
        #expect(LocalToken.matches("", ""))
        #expect(!LocalToken.matches(token, String(repeating: "ab", count: 31) + "ac"))
        #expect(!LocalToken.matches(token, String(token.dropLast())))
        #expect(!LocalToken.matches("", token))
    }
}
