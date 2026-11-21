import Foundation
import os

/// Whether a failed Pond write could have reached the Pond.
public enum DeliveryCertainty: String, Sendable, Equatable {
    /// The request never left this Mac: DNS, connect or TLS failed, or the timeout fell
    /// before the request was written. Sending it again can't make a duplicate.
    case notSent
    /// The request may have reached the Pond (a timeout after sending, a dropped
    /// connection, a gateway error). The ask is read again before anything is resent.
    case maybeSent
}

/// The timing of one Pond request, from `URLSessionTaskMetrics`, cut down to numbers and
/// fixed labels: never a URL, a host, an address or a header.
public struct PondTiming: Sendable, Equatable {
    public enum Family: String, Sendable { case ipv4, ipv6 }

    /// The whole task, waiting for connectivity included.
    public var total: TimeInterval?
    /// How many transactions the task made (0: it never opened a connection).
    public var transactions = 0
    public var dns: TimeInterval?
    public var connect: TimeInterval?
    public var tls: TimeInterval?
    /// Request written to first response byte.
    public var ttfb: TimeInterval?
    /// `h2`, `h3`, `http/1.1`.
    public var networkProtocol: String?
    public var reused: Bool?
    public var family: Family?
    /// The last transaction started writing the request.
    public var requestSent = false

    public init(total: TimeInterval? = nil, transactions: Int = 0, dns: TimeInterval? = nil,
                connect: TimeInterval? = nil, tls: TimeInterval? = nil, ttfb: TimeInterval? = nil,
                networkProtocol: String? = nil, reused: Bool? = nil, family: Family? = nil,
                requestSent: Bool = false) {
        self.total = total; self.transactions = transactions; self.dns = dns; self.connect = connect
        self.tls = tls; self.ttfb = ttfb; self.networkProtocol = networkProtocol; self.reused = reused
        self.family = family; self.requestSent = requestSent
    }

    public init(_ metrics: URLSessionTaskMetrics) {
        total = metrics.taskInterval.duration
        let network = metrics.transactionMetrics.filter { $0.resourceFetchType == .networkLoad }
        transactions = network.count
        // Any transaction that wrote a request counts: a retried connection may follow it.
        requestSent = network.contains { $0.requestStartDate != nil }
        guard let last = network.last else { return }
        dns = Self.span(last.domainLookupStartDate, last.domainLookupEndDate)
        connect = Self.span(last.connectStartDate, last.connectEndDate)
        tls = Self.span(last.secureConnectionStartDate, last.secureConnectionEndDate)
        ttfb = Self.span(last.requestStartDate, last.responseStartDate)
        networkProtocol = last.networkProtocolName.map(Self.protocolLabel)
        reused = last.isReusedConnection
        family = last.remoteAddress.map(Self.family)
    }

    static func span(_ start: Date?, _ end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start))
    }

    /// Only the characters a protocol name uses, at most 16.
    static func protocolLabel(_ name: String) -> String {
        let kept = name.lowercased().unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "./-".unicodeScalars.contains($0))
        }
        let text = String(String.UnicodeScalarView(kept.prefix(16)))
        return text.isEmpty ? "?" : text
    }

    /// The address's family only; the address itself is never kept.
    static func family(_ address: String) -> Family { address.contains(":") ? .ipv6 : .ipv4 }

    /// `total=30012ms dns=3ms connect=41ms tls=88ms ttfb=- protocol=h2 reused=false addr=ipv4 sent=true tx=1`.
    public var fields: String {
        func ms(_ t: TimeInterval?) -> String { t.map { "\(Int(($0 * 1000).rounded()))ms" } ?? "-" }
        return [
            "total=\(ms(total))", "dns=\(ms(dns))", "connect=\(ms(connect))", "tls=\(ms(tls))", "ttfb=\(ms(ttfb))",
            "protocol=\(networkProtocol ?? "-")", "reused=\(reused.map(String.init) ?? "-")",
            "addr=\(family?.rawValue ?? "-")", "sent=\(requestSent)", "tx=\(transactions)",
        ].joined(separator: " ")
    }
}

/// How the Mac retries an owner's Pond write that failed on the network. Opt-in per client:
/// the phone dispatches each act once (`StoreDeliveryPolicy.phone`) and never gets one.
public struct PondRetryPolicy: Sendable {
    /// The wait before each retry; one retry per entry.
    public var delays: [Duration]
    /// No retry starts this long after the first attempt.
    public var deadline: Duration
    public var sleep: @Sendable (Duration) async throws -> Void
    /// `(askID, waiting)`: true when a send failed and waits for its retry, false when it is
    /// over (sent, found already there, or given up).
    public var onWaiting: @Sendable (String?, Bool) -> Void

    public init(delays: [Duration] = PondRetryPolicy.standardDelays, deadline: Duration = .seconds(120),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                onWaiting: @escaping @Sendable (String?, Bool) -> Void = { _, _ in }) {
        self.delays = delays
        self.deadline = deadline
        self.sleep = sleep
        self.onWaiting = onWaiting
    }

    /// Three retries: 2 s, 5 s, then 15 s after a failure.
    public static let standardDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]

    /// What a failure before any HTTP answer means for a resend; nil when retrying can't help
    /// (a cancelled request, a certificate that isn't trusted, a bad URL).
    public static func certainty(for error: URLError, timing: PondTiming?) -> DeliveryCertainty? {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .notConnectedToInternet,
             .secureConnectionFailed, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
            return .notSent
        case .timedOut, .networkConnectionLost, .badServerResponse, .cannotParseResponse,
             .zeroByteResource, .cannotDecodeRawData:
            // Metrics that show no request was written prove the Pond never saw it.
            if let timing, !timing.requestSent { return .notSent }
            return .maybeSent
        default:
            return nil
        }
    }

    /// A gateway error may come after the Pond acted; every other status is the Pond's answer.
    public static func certainty(forStatus status: Int) -> DeliveryCertainty? {
        [502, 503, 504].contains(status) ? .maybeSent : nil
    }
}

/// How a write is confirmed after a "maybe sent" failure, read from the ask as the Pond has it.
enum WriteLanding: Sendable {
    /// Sending it again changes nothing the owner or the session sees (the Pond dedupes it,
    /// or the act sets a state): resend without looking.
    case resend
    /// One owner event of this kind with this text, newer than the ones seen before the send.
    case event(kind: String, text: String)
    /// A problem report on this step with this note.
    case problem(stepID: String, note: String)
    /// The ask has this status (a Done or a Skip).
    case status(String)

    /// Events at most this much older than the send's start (by this Mac's clock) count as
    /// it when no earlier read of the ask gives a baseline: the Pond's clock may differ.
    static let clockSlack: TimeInterval = 120

    /// True when `detail` already holds this write.
    func landed(in detail: AskDetail, after baseline: Int?, since start: Date) -> Bool {
        switch self {
        case .resend:
            return false
        case .status(let status):
            return detail.item.status == status
        case .event(let kind, let text):
            return newOwnerEvents(detail, kind: kind, after: baseline, since: start).contains { $0.text == text }
        case .problem(let stepID, let note):
            return newOwnerEvents(detail, kind: "problem", after: baseline, since: start).contains { event in
                guard let data = event.text?.data(using: .utf8),
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return body["id"] as? String == stepID && body["note"] as? String == note
            }
        }
    }

    private func newOwnerEvents(_ detail: AskDetail, kind: String, after baseline: Int?, since start: Date) -> [Event] {
        detail.events.filter { event in
            guard event.kind == kind, event.actor == "owner" else { return false }
            if let baseline { return event.seq > baseline }
            guard let at = Timestamp.date(event.at) else { return false }
            return at >= start.addingTimeInterval(-Self.clockSlack)
        }
    }
}

/// The newest event seq this client has read per ask, so a "maybe sent" check only counts
/// events that came after it. Memory only; bounded.
final class SeenEvents: Sendable {
    private let latest = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])
    static let limit = 500

    func note(_ detail: AskDetail) {
        guard let top = detail.events.map(\.seq).max() else { return }
        latest.withLock { map in
            if map.count >= Self.limit, map[detail.item.id] == nil { map.removeAll(keepingCapacity: true) }
            map[detail.item.id] = max(map[detail.item.id] ?? top, top)
        }
    }

    func baseline(_ id: String) -> Int? { latest.withLock { $0[id] } }
}

/// The per-request delegate: refuses redirects (the bearer token only reaches the configured
/// Pond) and keeps the task's timing.
final class PondTaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let collected = OSAllocatedUnfairLock<PondTiming?>(initialState: nil)

    var timing: PondTiming? { collected.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let timing = PondTiming(metrics)
        collected.withLock { $0 = timing }
    }

    /// The timing, waiting a moment for it when the failure arrived first.
    func awaitTiming() async -> PondTiming? {
        for _ in 0..<10 {
            if let timing { return timing }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return timing
    }
}
