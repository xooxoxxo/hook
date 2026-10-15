import Foundation
import Network
import RelayCore

/// The listener's state: shown in the footer and the Queue tab, and in local
/// mode it decides whether the menu bar is dimmed.
enum ListenerState: Equatable {
    case starting
    case ready
    /// A sentence for the UI, e.g. "Port 47823 is in use by another app".
    case failed(String)
}

/// HTTP on 127.0.0.1 only. Per connection: read the head (at most
/// 16 KB), apply `RequestFraming`, read exactly the body, then dispatch:
/// `/i/<uuid>` → `LinkPolicy`; `/health` → the health handler after LinkPolicy's
/// Host check; anything else → `LocalAPI`, or 404 when the source isn't local.
/// Every connection has a 5 s deadline, and at most 8 are open at once.
@MainActor final class LoopbackServer {
    static let maxHeadBytes = 16 * 1024
    static let maxConnections = 8
    static let connectionDeadline: Duration = .seconds(5)
    static let retryDelay: Duration = .seconds(10)

    /// A request whose head passed framing, waiting for its body.
    private struct Pending: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        /// The raw request target, query included, for `LinkPolicy`.
        let target: String
        let bodyLength: Int
    }

    private struct OpenConnection {
        let connection: NWConnection
        let deadline: Task<Void, Never>
    }

    private let port: UInt16
    private let onOpen: @MainActor (String) -> Void
    private let onState: @MainActor (ListenerState) -> Void
    private let health: @Sendable (_ nonce: String?) -> HTTPResponse
    private let api: @Sendable () -> LocalAPI?
    private var listener: NWListener?
    private var retry: Task<Void, Never>?
    private var stopped = false
    private var connections: [ObjectIdentifier: OpenConnection] = [:]

    init(
        port: UInt16,
        onOpen: @escaping @MainActor (String) -> Void,
        onState: @escaping @MainActor (ListenerState) -> Void,
        health: @escaping @Sendable (_ nonce: String?) -> HTTPResponse,
        api: @escaping @Sendable () -> LocalAPI?
    ) {
        self.port = port
        self.onOpen = onOpen
        self.onState = onState
        self.health = health
        self.api = api
    }

    /// Never throws: problems arrive through `onState`.
    func start() {
        stopped = false
        guard listener == nil else { return }
        onState(.starting)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            onState(.failed(Self.failureText(error, port: port)))
            scheduleRetry()
            return
        }
        let id = ObjectIdentifier(listener)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection, listener: id) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(state, listener: id) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    func stop() {
        stopped = true
        retry?.cancel()
        retry = nil
        listener?.cancel()
        listener = nil
        for open in connections.values {
            open.deadline.cancel()
            open.connection.cancel()
        }
        connections = [:]
    }

    // MARK: - Listener

    private func listenerChanged(_ state: NWListener.State, listener id: ObjectIdentifier) {
        guard let listener, ObjectIdentifier(listener) == id else { return }
        switch state {
        case .ready:
            onState(.ready)
        case .waiting(let error):
            onState(.failed(Self.failureText(error, port: port)))
        case .failed(let error):
            NSLog("Relay: loopback listener on port %d failed", Int(port))
            listener.cancel()
            self.listener = nil
            onState(.failed(Self.failureText(error, port: port)))
            scheduleRetry()
        default:
            break
        }
    }

    private func scheduleRetry() {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: Self.retryDelay)
            guard let self, !Task.isCancelled, !self.stopped, self.listener == nil else { return }
            self.start()
        }
    }

    static func failureText(_ error: any Error, port: UInt16) -> String {
        if let error = error as? NWError, case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is in use by another app"
        }
        return "Relay can't listen on port \(port): \(error.localizedDescription)"
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection, listener id: ObjectIdentifier) {
        guard let listener, ObjectIdentifier(listener) == id,
              connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.connectionDeadline)
            guard !Task.isCancelled else { return }
            self?.close(key)
        }
        connections[key] = OpenConnection(connection: connection, deadline: deadline)
        connection.start(queue: .main)
        readHead(connection, buffer: Data())
    }

    private func close(_ key: ObjectIdentifier) {
        guard let open = connections.removeValue(forKey: key) else { return }
        open.deadline.cancel()
        open.connection.cancel()
    }

    /// Reads until the blank line that ends the head.
    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else {
                    connection.cancel()
                    return
                }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    guard end.upperBound <= Self.maxHeadBytes else {
                        self.respond(connection, .error(400, "bad request"))
                        return
                    }
                    self.headReceived(
                        connection,
                        head: Data(buffer[buffer.startIndex..<end.upperBound]),
                        rest: Data(buffer[end.upperBound...]))
                } else if buffer.count > Self.maxHeadBytes {
                    self.respond(connection, .error(400, "bad request"))
                } else if isComplete || error != nil {
                    self.close(ObjectIdentifier(connection))
                } else {
                    self.readHead(connection, buffer: buffer)
                }
            }
        }
    }

    /// Framing comes before Host, auth or anything else.
    private func headReceived(_ connection: NWConnection, head: Data, rest: Data) {
        guard let parsed = HTTPRequest.parseHead(head), let target = Self.target(head) else {
            respond(connection, .error(400, "bad request"))
            return
        }
        switch RequestFraming.decide(method: parsed.method, headers: parsed.headers) {
        case .reject(let response):
            respond(connection, response)
        case .read(let bodyLength):
            let pending = Pending(
                method: parsed.method, path: parsed.path, query: parsed.query,
                headers: parsed.headers, target: target, bodyLength: bodyLength)
            readBody(connection, pending, body: rest)
        }
    }

    /// Reads exactly `bodyLength` bytes; anything after them is ignored.
    private func readBody(_ connection: NWConnection, _ pending: Pending, body: Data) {
        if body.count >= pending.bodyLength {
            dispatch(connection, pending, body: Data(body.prefix(pending.bodyLength)))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: RequestFraming.maxBody) {
            [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else {
                    connection.cancel()
                    return
                }
                var body = body
                if let data { body.append(data) }
                if body.count >= pending.bodyLength {
                    self.dispatch(connection, pending, body: Data(body.prefix(pending.bodyLength)))
                } else if isComplete || error != nil {
                    self.close(ObjectIdentifier(connection))
                } else {
                    self.readBody(connection, pending, body: body)
                }
            }
        }
    }

    private func dispatch(_ connection: NWConnection, _ pending: Pending, body: Data) {
        let port = Int(self.port)
        if pending.path.hasPrefix("/i/") {
            switch LinkPolicy.decide(method: pending.method, path: pending.target, headers: pending.headers, port: port) {
            case .open(let id):
                respond(connection, Self.linkPage(200))
                onOpen(id)
            case .forbidden:
                respond(connection, .error(403, "forbidden"))
            case .notFound, .health:
                respond(connection, Self.linkPage(404))
            }
            return
        }
        if pending.path == "/health" {
            switch LinkPolicy.decide(method: pending.method, path: "/health", headers: pending.headers, port: port) {
            case .health:
                respond(connection, health(pending.headers["x-relay-nonce"]))
            case .forbidden:
                respond(connection, .error(403, "forbidden"))
            case .notFound, .open:
                respond(connection, .error(404, "not found"))
            }
            return
        }
        guard let api = api() else {
            respond(connection, .error(404, "not found"))
            return
        }
        let request = HTTPRequest(
            method: pending.method, path: pending.path, query: pending.query,
            headers: pending.headers, body: body)
        Task { [weak self] in
            let response = await api.handle(request)
            self?.respond(connection, response)
        }
    }

    /// Sends once and closes. A connection already closed (deadline) is skipped.
    private func respond(_ connection: NWConnection, _ response: HTTPResponse) {
        let key = ObjectIdentifier(connection)
        guard connections[key] != nil else { return }
        connection.send(
            content: response.serialized(),
            completion: .contentProcessed { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self {
                        self.close(key)
                    } else {
                        connection.cancel()
                    }
                }
            })
    }

    // MARK: - Helpers

    /// The raw target of "METHOD target HTTP/1.x"; nil when the line is malformed.
    static func target(_ head: Data) -> String? {
        guard let text = String(data: head, encoding: .isoLatin1),
              let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        return parts.count == 3 ? String(parts[1]) : nil
    }

    /// The same page whether or not the id exists, so a request learns nothing.
    static func linkPage(_ status: Int) -> HTTPResponse {
        LinkPage.response(status: status)
    }
}
