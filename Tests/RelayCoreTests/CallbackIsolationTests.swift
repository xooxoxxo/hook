import Foundation
import Testing
@testable import RelayCore

/// A stand-in for an Objective-C completion-handler API: it calls back on a background queue,
/// the way macOS 27's UNUserNotificationCenter.getNotificationSettings does.
private func callsBackOnAWorker(_ handler: @escaping @Sendable (Int) -> Void) {
    DispatchQueue.global(qos: .utility).async { handler(Int(pthread_main_np())) }
}

@MainActor private final class MainActorOwner {
    /// The shape of Notifier.permission(): a main-actor type awaiting a background callback.
    func read() async -> Int {
        await CallbackHop.value { done in
            callsBackOnAWorker { @Sendable onMain in done(onMain) }
        }
    }
}

@Suite struct CallbackIsolationTests {
    @Test @MainActor func aMainActorTypeAwaitsABackgroundCallbackWithoutTrapping() async {
        let owner = MainActorOwner()
        // The callback ran off the main thread (pthread_main_np 0), and the await resumed here.
        #expect(await owner.read() == 0)
        #expect(pthread_main_np() == 1)
        for _ in 0..<50 { _ = await owner.read() }
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// System APIs that can call their handler on any queue. A closure literal handed to one
    /// must be `@Sendable` on the line that opens it, so it can never be inferred main-actor
    /// isolated (the 0.12 macOS 27 crash). The async overloads (`await center.add(…)`) don't count.
    static let backgroundCallbacks = [
        "getNotificationSettings", "getDeliveredNotifications", "getPendingNotificationRequests",
        "requestAuthorization(options:", "add(_:withCompletionHandler", "evaluatePolicy(",
        "readabilityHandler =", "writeabilityHandler =", "terminationHandler =", "coordinate(",
        "scheduledTimer(", "Timer(timeInterval", "dataTask(", "downloadTask(", "uploadTask(",
        "NSWorkspace.shared.open(", "openApplication(at:", "recycle(", "requestRecordPermission",
    ]

    /// Lines that hand a closure literal to one of those APIs (or to an observer with
    /// `queue: nil`, posted on any thread) without `@Sendable`.
    static func offenders(in text: String, file: String) -> [String] {
        var found: [String] = []
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            let code = line.components(separatedBy: "//").first ?? line
            guard !code.contains("await "),
                  let api = (backgroundCallbacks + ["queue: nil"]).compactMap({ code.range(of: $0) }).first
            else { continue }
            // A closure literal that opens after the call: `{ x in`, `{ [self] x in`, or `{` at the end.
            let after = String(code[api.upperBound...])
            guard let brace = after.firstIndex(of: "{") else { continue }
            let closure = String(after[brace...])
            let opens = closure.range(of: #"^\{\s*(\[[^\]]*\]\s*)?[\w, ]*\bin\b"#, options: .regularExpression) != nil
                || closure.trimmingCharacters(in: .whitespaces) == "{" || closure.hasPrefix("{ @")
            guard opens, !closure.contains("@Sendable") else { continue }
            found.append("\(file):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
        return found
    }

    @Test func everyBackgroundCallbackInTheSourcesIsSendable() throws {
        let sources = Self.root.appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50)
        var offenders: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            offenders += Self.offenders(in: text, file: url.lastPathComponent)
        }
        #expect(offenders.isEmpty, Comment(rawValue: "Mark these closures @Sendable and hop to the main actor "
            + "explicitly:\n" + offenders.joined(separator: "\n")))
    }

    @Test func theCheckCatchesTheShapeThatCrashed() {
        let bad = """
            UNUserNotificationCenter.current().getNotificationSettings { current in
                continuation.resume(returning: current.authorizationStatus.rawValue)
            }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: c) { _, error in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
            handle.readabilityHandler = { [self] handle in
            """
        #expect(Self.offenders(in: bad, file: "x").count == 4)
        let good = """
            UNUserNotificationCenter.current().getNotificationSettings { @Sendable current in
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: c) { @Sendable _, error in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
            try? await UNUserNotificationCenter.current().add(request)
            NSWorkspace.shared.open(url)
            """
        #expect(Self.offenders(in: good, file: "x").isEmpty)
    }
}
