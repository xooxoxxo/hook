import Foundation
import RelayCore

/// Generic gallery and test data. The repo is public: projects are Acme, Northwind,
/// Atlas and Relay; no real names, hosts, paths or private projects.
public enum GalleryFixtures {
    public static let now = Timestamp.date("2026-10-16T09:40:00+00:00")!

    static func ago(_ hours: Double) -> String { Timestamp.string(now.addingTimeInterval(-hours * 3600)) }

    static func ask(_ id: String, _ project: String, _ urgency: String, hoursAgo: Double, _ ins: Instructable,
                    status: String = "open", completedHoursAgo: Double? = nil) -> WireItem {
        WireItem(id: id, title: ins.title, status: status, projectId: project, created: ago(hoursAgo), updated: ago(hoursAgo),
                 payload: Payload(why: nil, cmd: nil, link: nil, instructable: ins),
                 completedAt: completedHoursAgo.map(ago))
    }

    static func steps(_ n: Int, _ prefix: String) -> [Step] { (1...n).map { Step(action: "\(prefix) \($0)") } }

    static let certSteps: [Step] = [
        Step(action: "Make a folder for the new certificate", place: "Mac terminal", code: "mkdir -p ~/certs/staging",
             expect: "The command prints nothing"),
        Step(action: "Request the staging certificate", place: "Certificate portal", substeps: [
            Step(action: "Click New Request, then Server Certificate", url: "https://portal.example.com/requests"),
            Step(action: "Name it Acme staging and choose a one-year term"),
            Step(action: "Under Alternative names, add this host", code: "staging.example.com", lang: "text"),
        ]),
        Step(action: "Check the new certificate's end date", place: "Mac terminal",
             code: "openssl x509 -in ~/certs/staging/cert.pem -noout -enddate"),
        Step(action: "Make a new deploy key", place: "Developer dashboard",
             detail: "Open Deploy keys and click Add Key. Name it Acme staging, give it read access only, then save. The key is shown once, on the next page, so keep that page open until you have saved it in the next step. Anyone with the key can read the staging repo.",
             url: "https://www.example.com/developer/keys"),
        Step(action: "Save the key in the Keychain; paste it when asked (it stays hidden)", place: "Mac terminal",
             code: "security add-generic-password -a deploy -s acme-staging -U -w", lang: "bash", expect: "You are back at the prompt"),
    ]

    static let origin = Origin(session: "1b2c3d4e-0000-4000-8000-000000000001", host: "example-mac", cwd: "~/src/acme")
    /// The same origin with an absolute folder, so the From disclosure shows its Resume row.
    public static let fromWithResume = AskOrigin(from: Origin(session: "1b2c3d4e-0000-4000-8000-000000000001",
                                                              host: "example-mac", cwd: "/work/acme"))!

    static let cert = ask("acme-1", "Acme", "now", hoursAgo: 3, Instructable(
        v: 1, title: "Renew the staging certificate and the deploy key",
        why: "The staging certificate runs out on Friday, and the new deploy key replaces the one that went with it.",
        urgency: "now", steps: certSteps,
        verify: Step(action: "Check the key is saved", place: "Mac terminal",
                     code: "security find-generic-password -s acme-staging -a deploy >/dev/null && echo key-ok", expect: "key-ok"),
        reply: ReplySpec(prompt: "Paste the new certificate's serial number", choices: []),
        links: [LinkRef(label: "Certificate portal help", url: "https://portal.example.com/help")], from: origin))

    static let region = ask("acme-2", "Acme", "today", hoursAgo: 9, Instructable(
        v: 1, title: "Choose the backup region", urgency: "today",
        steps: [Step(action: "Pick where the nightly backups are kept")],
        reply: ReplySpec(prompt: "Which region should the backups use?", choices: ["Europe", "North America"])))

    public static let open: [WireItem] = [
        cert, region,
        ask("acme-3", "Acme", "today", hoursAgo: 10, Instructable(v: 1, title: "Review the onboarding checklist",
                                                                  urgency: "today", steps: steps(4, "Review part"))),
        ask("relay-1", "Relay", "whenever", hoursAgo: 24, Instructable(v: 1, title: "Send the release notes draft",
                                                                       urgency: "whenever", steps: steps(2, "Write section"))),
        ask("northwind-1", "Northwind", "whenever", hoursAgo: 48, Instructable(v: 1, title: "Pick a colour for the dashboard theme",
                                                                               urgency: "whenever", steps: steps(3, "Compare option"))),
    ]

    public static let closed: [WireItem] = [
        ask("acme-c1", "Acme", "today", hoursAgo: 20, Instructable(v: 1, title: "Rotate the backup password", steps: steps(1, "Rotate")),
            status: "done", completedHoursAgo: 3),
        ask("relay-c1", "Relay", "today", hoursAgo: 26, Instructable(v: 1, title: "Proofread the changelog", steps: steps(1, "Read")),
            status: "done", completedHoursAgo: 2),
    ]

    /// Step 1 and sub-step 2b done: 2a is the current step.
    static let certTicks: Set<String> = ["1", "2.2"]
    static let drafts = ["acme-3": "Two items still need an owner"]

    public static func queue(grouping: QueueGrouping, filter: String?, closedExpanded: Bool) -> QueueSnapshot {
        QueueSnapshot.build(
            open: open, closed: closed, grouping: grouping, filter: filter,
            ticks: { $0 == "acme-1" ? certTicks : [] }, drafts: drafts, closedBy: { _ in "owner" },
            sourceKey: "mailbox:mailbox.example#personal", loadedOnce: true, reachable: true, problem: nil,
            waitedTenSeconds: false, manualRefreshing: false, updated: "09:40")
    }

    public static let detailSteps = DetailSnapshot.build(
        item: cert,
        detail: AskDetail(item: cert, events: [Event(seq: 2, itemId: "acme-1", kind: "reply", actor: "owner",
                                                     text: "4A3F09C2B1", at: "2026-10-16T09:31:00+00:00")]),
        ticks: certTicks, load: .loaded, reply: .idle, draft: nil, pendingChoice: nil, busy: false,
        previous: .end, next: .ask("acme-2"), closedBy: nil)

    public static let detailChoice = DetailSnapshot.build(
        item: region, detail: AskDetail(item: region, events: []), ticks: [], load: .loaded, reply: .idle, draft: nil,
        pendingChoice: nil, busy: false, previous: .ask("acme-1"), next: .ask("acme-3"), closedBy: nil)

    /// Every validator maximum: 120-char title; 20 steps, 4 of them with 10 sub-steps (60 in all);
    /// a 1500-char detail; a 4000-char code block; 6 choices of 60; 10 links.
    public static let limitsItem: WireItem = {
        let title = String(String(repeating: "Rotate every example key on the staging hosts and confirm ", count: 3).prefix(120))
        var list: [Step] = (1...20).map { n in
            Step(action: "Do part \(n) of the rotation", place: "Mac terminal",
                 substeps: n <= 4 ? (1...10).map { Step(action: "Sub-step \($0) of part \(n)") } : nil)
        }
        list[4].detail = String(String(repeating: "Read the whole note before you start. ", count: 40).prefix(1500))
        list[5].code = String(String(repeating: "echo rotate-step-ok && ", count: 200).prefix(4000))
        let choices = (1...6).map { String(String(repeating: "Choice \($0) with a long label ", count: 3).prefix(60)) }
        let links = (1...10).map { LinkRef(label: "Runbook page \($0)", url: "https://docs.example.com/runbook/\($0)") }
        return ask("atlas-limits", "Atlas", "today", hoursAgo: 1, Instructable(
            v: 1, title: title, urgency: "today", steps: list, verify: Step(action: "Check the rotation", code: "echo ok"),
            reply: ReplySpec(prompt: "Which hosts are left?", choices: choices), links: links))
    }()

    public static let limits = DetailSnapshot.build(
        item: limitsItem, detail: AskDetail(item: limitsItem, events: []), ticks: [], load: .loaded, reply: .idle,
        draft: nil, pendingChoice: nil, busy: false, previous: .end, next: .end, closedBy: nil)

    public static let manyProjects: [WireItem] = {
        let names = ["Acme", "Northwind", "Atlas", "Relay", "Bluebird", "Cobalt", "Dune", "Ember", "Fjord", "Granite",
                     "Harbor", "Northern region warehouse inventory and shipping schedule v2"]
        return names.enumerated().map { index, name in
            ask("many-\(index)", name, index == 3 ? "now" : "today", hoursAgo: Double(index + 1),
                Instructable(v: 1, title: "Check the \(name) setup", urgency: index == 3 ? "now" : "today", steps: steps(2, "Check")))
        }
    }()
}
