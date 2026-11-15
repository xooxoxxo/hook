import Foundation
import Network
import os
import Testing
@testable import RelayCore

/// Loopback only. Delivering a byte every 1.5 seconds keeps a request-idle timeout
/// alive, but must not extend the Pond client's overall resource deadline.
private final class SlowPond: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.pond.slow-response")
    private let listener: NWListener
    private var connections: [NWConnection] = []  // accessed only on queue

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if let port = listener.port, resumed.withLock({ old in defer { old = true }; return !old }) {
                        continuation.resume(returning: port.rawValue)
                    }
                case .failed(let error):
                    if resumed.withLock({ old in defer { old = true }; return !old }) {
                        continuation.resume(throwing: error)
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, data != nil, error == nil else { connection.cancel(); return }
            let body = Array(#"{"items":[]}"#.utf8)
            let headers = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(headers.utf8), completion: .contentProcessed { error in
                guard error == nil else { connection.cancel(); return }
                self.drip(body, index: 0, connection: connection)
            })
        }
    }

    private func drip(_ bytes: [UInt8], index: Int, connection: NWConnection) {
        guard index < bytes.count else { connection.cancel(); return }
        connection.send(content: Data([bytes[index]]), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + 1.5) {
                self.drip(bytes, index: index + 1, connection: connection)
            }
        })
    }
}

@Suite struct PondConnectivityTests {
    @Test func aDefaultPondLoadHasAnOverallDeadlineEvenWhileBytesArrive() async throws {
        let server = try SlowPond()
        let port = try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "pond-deadline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = directory.appending(path: "token")
        try Data("synthetic-deadline-token".utf8).write(to: token)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)"))
        let client = MailboxClient(baseURL: url, tokenFile: token.path, context: "test")
        let log = RollingLog(directory: directory.appending(path: "logs"), now: { Date() })
        let began = ContinuousClock.now
        await HookLog.withLog(log) {
            do {
                _ = try await client.list()
                Issue.record("The default client allowed a slow response to outlive its resource deadline")
            } catch QueueError.unreachable { }
            catch { Issue.record("Unexpected failure: \(type(of: error))") }
        }
        #expect(began.duration(to: .now) < .seconds(20))
        #expect(log.tail(5).contains { $0.contains("URLError -1001") })
    }
}
