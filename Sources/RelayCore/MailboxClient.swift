import Foundation

struct ListResponse: Decodable {
    let items: [WireItem]
}

struct ItemResponse: Decodable {
    let item: WireItem
}

struct ErrorBody: Decodable {
    let error: String
    let details: [String]?
}

/// Refuses every HTTP redirect, so the bearer token only ever reaches the configured mailbox.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// The mailbox service as a `QueueSource`. The token is read from the token file
/// on every request, so it is never kept in memory longer than one call.
public struct MailboxClient: QueueSource {
    public let settings: MailboxSettings
    private let session: URLSession

    public init(settings: MailboxSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    public init(baseURL: URL, tokenFile: String, context: String, session: URLSession = .shared) {
        self.init(settings: MailboxSettings(url: baseURL, tokenFile: tokenFile, context: context), session: session)
    }

    public func list() async throws -> [WireItem] {
        let query = [
            URLQueryItem(name: "status", value: "open"),
            URLQueryItem(name: "days", value: "36500"),
        ]
        let response: ListResponse = try await send("GET", "asks", query: query)
        return response.items
    }

    public func get(_ id: String) async throws -> AskDetail {
        try await send("GET", "asks/\(id)")
    }

    public func post(project: String, instructable: Data) async throws -> PostResult {
        let body = Self.postBody(project: project, context: settings.context, instructable: instructable)
        return try await send("POST", "asks", body: body)
    }

    /// Done or Skip from Relay: always `actor: "owner"`.
    public func resolve(_ id: String, verdict: Verdict, note: String?) async throws -> WireItem {
        var body = ["verdict": verdict.rawValue, "actor": "owner"]
        if let note { body["note"] = note }
        let response: ItemResponse = try await send("POST", "asks/\(id)/resolve", body: Self.encode(body))
        return response.item
    }

    public func reply(_ id: String, text: String) async throws -> WireItem {
        let response: ItemResponse = try await send("POST", "asks/\(id)/reply", body: Self.encode(["text": text]))
        return response.item
    }

    /// Takes back a Done or Skip: always `actor: "owner"`. The mailbox returns an open
    /// ask unchanged.
    public func reopen(_ id: String) async throws -> WireItem {
        let response: ItemResponse = try await send("POST", "asks/\(id)/reopen", body: Self.encode(["actor": "owner"]))
        return response.item
    }

    /// The mailbox's `days` filter counts from creation, so both lists reach back
    /// `closedLookbackDays`; the completion window is applied here.
    public func recentlyClosed(within interval: TimeInterval) async throws -> [WireItem] {
        var merged: [WireItem] = []
        for status in ["done", "dismissed"] {
            let query = [
                URLQueryItem(name: "status", value: status),
                URLQueryItem(name: "days", value: String(Self.closedLookbackDays)),
            ]
            let response: ListResponse = try await send("GET", "asks", query: query)
            merged += response.items
        }
        return Self.closedWithin(merged, interval: interval, now: Date())
    }

    static let closedLookbackDays = 14

    /// Items whose `completedAt` is within `interval` of `now`, newest first. One
    /// without a readable `completedAt` is skipped; an id seen twice is kept once.
    static func closedWithin(_ items: [WireItem], interval: TimeInterval, now: Date) -> [WireItem] {
        let cutoff = now.addingTimeInterval(-interval)
        var seen = Set<String>()
        return items
            .compactMap { item -> (completed: Date, item: WireItem)? in
                guard item.status != "open",
                      let completed = item.completedAt.flatMap(Timestamp.date),
                      completed >= cutoff, seen.insert(item.id).inserted else { return nil }
                return (completed, item)
            }
            .sorted { $0.completed > $1.completed }
            .map(\.item)
    }

    /// The mailbox has no push channel; the Store polls.
    public func changes() async -> AsyncStream<Void>? {
        nil
    }

    /// `{"context":…,"project":…,"instructable":<raw>}`: the instructable's bytes
    /// are spliced in as given, so the mailbox validates exactly what the caller sent.
    static func postBody(project: String, context: String, instructable: Data) -> Data {
        var body = encode(["context": context, "project": project])
        body.removeLast()   // the closing brace
        body.append(Data(#","instructable":"#.utf8))
        body.append(instructable)
        body.append(Data("}".utf8))
        return body
    }

    static func encode(_ object: [String: String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }

    private func send<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> T {
        var components = URLComponents(
            url: settings.url.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw QueueError.unreachable("the mailbox URL is not valid") }

        let token: String
        do {
            token = try settings.readToken()
        } catch {
            throw QueueError.unreachable(error.localizedDescription)   // names the file's path, never its content
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request, delegate: NoRedirectDelegate.shared)
        } catch let error as URLError {
            throw QueueError.unreachable(error.localizedDescription)
        } catch {
            throw QueueError.unreachable("the request failed")
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw QueueError.unreachable("bad response from the mailbox")
        }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw QueueError.unreachable("bad response from the mailbox")
            }
        case 300..<400:
            throw QueueError.unreachable("the mailbox answered with a redirect (\(http.statusCode)); not following it")
        case 401:
            throw QueueError.unauthorized
        case 404:
            throw QueueError.notFound
        default:
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw QueueError.rejected(
                status: http.statusCode,
                error: body?.error ?? "HTTP \(http.statusCode)",
                details: body?.details ?? [])
        }
    }
}
